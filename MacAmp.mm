#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <vector>
#include <unistd.h>

#import "FxPreset.mm"

struct Effect {
    float low[2]{}, envelope = 0, bass = 0, attack = 0, release = 0;
    float strength = 1, smoothing = 0;
    void configure(double rate, float initial = 1) {
        strength = initial;
        smoothing = 1 - exp(-1 / (.02 * rate));
        bass = 1 - exp(-2 * M_PI * 150 / rate);
        attack = 1 - exp(-1 / (.004 * rate));
        release = 1 - exp(-1 / (.14 * rate));
    }
    void frame(float &left, float &right, float target = 1) {
        strength += smoothing * (target - strength);
        float v[2] = {left, right};
        for (int c = 0; c < 2; ++c) {
            low[c] += bass * (v[c] - low[c]);
            v[c] += .25f * strength * low[c];
        }
        float peak = std::max(fabsf(v[0]), fabsf(v[1]));
        envelope += (peak > envelope ? attack : release) * (peak - envelope);
        float gain = 1 + .85f * strength;
        if (envelope > .28f) gain *= sqrtf(.28f / envelope);
        // Smooth the last few dB of headroom while leaving quieter samples linear.
        auto limit = [](float x) {
            float a = fabsf(x);
            return a <= .75f ? x : copysignf(.75f + .23f * tanhf((a - .75f) / .23f), x);
        };
        left = limit(v[0] * gain);
        right = limit(v[1] * gain);
    }
};

static OSStatus readProp(AudioObjectID obj, AudioObjectPropertySelector sel, void *out, UInt32 size,
                         AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    AudioObjectPropertyAddress a{sel, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(obj, &a, 0, nullptr, &size, out);
}
struct Engine {
    AudioObjectID device{}, tap{}, aggregate{};
    AudioDeviceIOProcID proc{};
    unsigned inputIndex{}, inputChannels{}, outputChannels{};
    double rate{};
    struct Route {
        bool prototype{};
        Effect effect;
        FactoryEffect factory;
        void frame(float &l,float &r,float strength) {
            if(prototype) effect.frame(l,r,strength);
            else factory.frame(l,r);
        }
    };
    NSMutableArray<NSDictionary *> *parameters;
    int selected{};
    Route *active{}, *previous{};
    std::atomic<Route*> pending{}, retired{};
    float blend{}, step{};

    Route *prepare(int index) {
        Route *route=new Route;
        route->prototype=index==0;
        if(index) route->factory.configure(parameters[index-1],rate);
        else route->effect.configure(rate,intensity.load()/100.f);
        return route;
    }
    void select(int index) {
        selected=index;
        if(!proc) return;
        delete retired.exchange(nullptr);
        delete pending.exchange(prepare(index));
    }
    std::atomic<int> intensity{100};
    std::atomic<bool> invalid{false}, signal{false};
    static OSStatus render(AudioDeviceID, const AudioTimeStamp*, const AudioBufferList *in,
                           const AudioTimeStamp*, AudioBufferList *out, const AudioTimeStamp*, void *ctx) {
        auto &e = *static_cast<Engine*>(ctx);
        for (unsigned i=0; i<out->mNumberBuffers; i++)
            if (out->mBuffers[i].mData) memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
        auto channel = [](const AudioBufferList *list, unsigned idx, unsigned stride, unsigned side,
                          unsigned &frames) -> float* {
            unsigned b = idx + (stride == 1 ? side : 0);
            if (b >= list->mNumberBuffers) return nullptr;
            auto &buf = list->mBuffers[b];
            if (!buf.mData || buf.mNumberChannels != stride) return nullptr;
            frames = std::min(frames, unsigned(buf.mDataByteSize / (sizeof(float)*stride)));
            return static_cast<float*>(buf.mData) + (stride == 1 ? 0 : side);
        };
        unsigned n = UINT_MAX;
        float *l = channel(in,e.inputIndex,e.inputChannels,0,n), *r = channel(in,e.inputIndex,e.inputChannels,1,n);
        float *ol = channel(out,0,e.outputChannels,0,n), *orr = channel(out,0,e.outputChannels,1,n);
        if (!l || !r || !ol || !orr) { e.invalid.store(true); return noErr; }
        bool audible = false;
        float target = e.intensity.load(std::memory_order_relaxed) / 100.f;
        // Only exchange ownership at buffer boundaries. Allocation and deletion stay on the UI thread.
        if(!e.previous && !e.retired.load()) {
            if(Route *next=e.pending.exchange(nullptr)) {
                e.previous=e.active; e.active=next; e.blend=0;
            }
        }
        for (unsigned i=0; i<n; ++i) {
            float a = l[i*e.inputChannels], b = r[i*e.inputChannels];
            audible |= fabsf(a) + fabsf(b) > .0001f;
            float originalL=a, originalR=b;
            e.active->frame(a,b,target);
            if(e.previous) {
                e.previous->frame(originalL,originalR,target);
                e.blend=std::min(1.f,e.blend+e.step);
                a=originalL+(a-originalL)*e.blend;
                b=originalR+(b-originalR)*e.blend;
                if(e.blend==1.f) {
                    e.retired.store(e.previous);
                    e.previous=nullptr;
                }
            }
            ol[i*e.outputChannels] = a; orr[i*e.outputChannels] = b;
        }
        if (audible) e.signal.store(true);
        return noErr;
    }
    void stop() {
        if (proc) { AudioDeviceStop(aggregate,proc); AudioDeviceDestroyIOProcID(aggregate,proc); proc=nullptr; }
        delete active; active=nullptr; delete previous; previous=nullptr;
        delete pending.exchange(nullptr); delete retired.exchange(nullptr); parameters=nil;
        if (aggregate) { AudioHardwareDestroyAggregateDevice(aggregate); aggregate=0; }
        if (tap) { AudioHardwareDestroyProcessTap(tap); tap=0; }
    }
    bool layout(AudioObjectPropertyScope scope, bool last, unsigned &index, unsigned &stride) {
        AudioObjectPropertyAddress addr{kAudioDevicePropertyStreams,scope,0};
        UInt32 size=0;
        if (AudioObjectGetPropertyDataSize(aggregate,&addr,0,nullptr,&size) || !size) return false;
        std::vector<AudioStreamID> streams(size/sizeof(AudioStreamID));
        if (AudioObjectGetPropertyData(aggregate,&addr,0,nullptr,&size,streams.data())) return false;
        index = last ? unsigned(streams.size()-1) : 0;
        auto format = [&](unsigned i, AudioStreamBasicDescription &f) {
            return !readProp(streams[i],kAudioStreamPropertyVirtualFormat,&f,sizeof(f)) &&
                f.mFormatID==kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) &&
                f.mBitsPerChannel==32 && f.mSampleRate==rate && f.mBytesPerFrame==4*f.mChannelsPerFrame;
        };
        AudioStreamBasicDescription f{};
        if (!format(index,f)) return false;
        stride=f.mChannelsPerFrame;
        if (stride>=2) return !last || stride==2;
        if (stride!=1 || streams.size()<2) return false;
        if(last) --index;
        return format(last ? index : 1,f) && f.mChannelsPerFrame==1;
    }
    NSString *start() {
        invalid=false; signal=false;
        if(readProp(1,kAudioHardwarePropertyDefaultOutputDevice,&device,sizeof(device)) || !device)
            return @"No audio output is available.";
        CFStringRef uid=nullptr;
        if(readProp(device,kAudioDevicePropertyDeviceUID,&uid,sizeof(uid)) || !uid) return @"Could not read the output device.";
        NSString *outputUID=CFBridgingRelease(uid);
        if(readProp(device,kAudioDevicePropertyNominalSampleRate,&rate,sizeof(rate)) || !(rate>0)) return @"The output sample rate is unavailable.";
        parameters=[NSMutableArray array];
        NSString *error=loadFactory(parameters,rate);
        if(error) return error;
        active=prepare(selected); step=float(1/(.020*rate));
        pid_t pid=getpid(); AudioObjectID me=0; UInt32 size=sizeof(me);
        AudioObjectPropertyAddress addr{kAudioHardwarePropertyTranslatePIDToProcessObject,kAudioObjectPropertyScopeGlobal,0};
        if(AudioObjectGetPropertyData(1,&addr,sizeof(pid),&pid,&size,&me) || !me) return @"Could not identify the app’s audio process.";
        UInt32 transport=0;
        readProp(device,kAudioDevicePropertyTransportType,&transport,sizeof(transport));
        bool bluetooth=transport==kAudioDeviceTransportTypeBluetooth || transport==kAudioDeviceTransportTypeBluetoothLE;
        // A device-stream tap inherits the headset clock and format. A global mix can use a different rate.
        CATapDescription *desc=bluetooth
            ? [[CATapDescription alloc] initExcludingProcesses:@[@(me)] andDeviceUID:outputUID withStream:0]
            : [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[@(me)]];
        desc.name=@"MacAmp"; [desc setPrivate:YES]; desc.muteBehavior=CATapMutedWhenTapped;
        OSStatus s=AudioHardwareCreateProcessTap(desc,&tap);
        if(s) return [NSString stringWithFormat:@"Could not capture audio (%d). Check system audio recording permission.", (int)s];
        NSDictionary *config=@{@kAudioAggregateDeviceNameKey:@"MacAmp Monitor",
            @kAudioAggregateDeviceUIDKey:NSUUID.UUID.UUIDString, @kAudioAggregateDeviceIsPrivateKey:@YES,
            @kAudioAggregateDeviceMainSubDeviceKey:outputUID,
            @kAudioAggregateDeviceSubDeviceListKey:@[@{@kAudioSubDeviceUIDKey:outputUID}],
            @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:desc.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}],
            @kAudioAggregateDeviceTapAutoStartKey:@YES};
        s=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config,&aggregate);
        if(s) return [NSString stringWithFormat:@"Could not open the output device (%d).",(int)s];
        unsigned first=0;
        bool ready=false;
        for(int attempt=0;attempt<12;++attempt) {
            if(layout(kAudioObjectPropertyScopeInput,true,inputIndex,inputChannels) &&
               layout(kAudioObjectPropertyScopeOutput,false,first,outputChannels)) { ready=true; break; }
            usleep(20000);
        }
        if(!ready) {
            AudioStreamBasicDescription f{};
            readProp(tap,kAudioTapPropertyFormat,&f,sizeof(f));
            return [NSString stringWithFormat:@"Unsupported audio format. Capture: %.0f Hz (%u channels). Output: %.0f Hz.",f.mSampleRate,f.mChannelsPerFrame,rate];
        }
        s=AudioDeviceCreateIOProcID(aggregate,render,this,&proc);
        if(!s) s=AudioDeviceStart(aggregate,proc);
        return s ? [NSString stringWithFormat:@"Could not start audio (%d). Check system audio recording permission.",(int)s] : nil;
    }
};

#import "PresetCurve.mm"

static const AudioObjectPropertyAddress outputDevicesAddress{
    kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
static const AudioObjectPropertyAddress defaultOutputAddress{
    kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};

// The first click should operate a control even when another app owns the fullscreen Space.
@interface PanelButton : NSButton
@end
@implementation PanelButton
-(BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
@end

@interface ChoiceRows : NSView
@end
@implementation ChoiceRows
-(BOOL)isFlipped { return YES; }
@end

@interface Controller : NSObject <NSApplicationDelegate>
@end
@implementation Controller {
    NSWindow *window; NSButton *button; NSTextField *status; Engine engine;
    NSTimer *timer; NSUInteger quiet, retryTicks;
    NSStatusItem *menuItem; NSString *outputName;
    NSPanel *controlsPanel;
    NSButton *powerCommand;
    NSButton *quickOutput, *quickPreset;
    CGFloat expandedHeight;
    NSScrollView *choiceScroll;
    BOOL choosingOutput;
    id outsideClick, localClick;
    NSTimeInterval lastOutsideDown, lastIconDown;
    NSPopUpButton *profiles, *outputPicker;
    AudioObjectPropertyListenerBlock outputListener;
    NSSegmentedControl *collections;
    NSSlider *slider; NSTextField *strengthLabel, *presetTitle;
    PresetCurve *curve; NSButton *compare;
    NSInteger lastSelection[2], prior;
}
static NSTextField *label(NSString *text,NSRect rect,CGFloat size,NSFontWeight weight) {
    NSTextField *field=[NSTextField labelWithString:text];
    field.font=[NSFont systemFontOfSize:size weight:weight]; field.frame=rect;
    return field;
}
-(void)applicationDidFinishLaunching:(NSNotification*)note {
    window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,482,409)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title=@"MacAmp"; window.releasedWhenClosed=NO;
    NSView *view=window.contentView;
    NSTextField *title=label(@"MacAmp",NSMakeRect(70,351,210,36),27,NSFontWeightBold);
    NSImage *art=[[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"MacAmp" ofType:@"png"]];
    NSImageView *icon=[NSImageView imageViewWithImage:art];
    icon.frame=NSMakeRect(19,346,45,45);
    menuItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *mark=[NSImage imageWithSize:NSMakeSize(19,18) flipped:YES drawingHandler:^BOOL(NSRect rect) {
        [NSColor.blackColor setStroke];
        NSBezierPath *bars=[NSBezierPath bezierPath];
        bars.lineWidth=2.6; bars.lineCapStyle=NSLineCapStyleRound;
        [bars moveToPoint:NSMakePoint(4.8,8.5)]; [bars lineToPoint:NSMakePoint(3.1,13.6)];
        [bars moveToPoint:NSMakePoint(10.4,4.2)]; [bars lineToPoint:NSMakePoint(8.7,14.8)];
        [bars moveToPoint:NSMakePoint(16,5.9)]; [bars lineToPoint:NSMakePoint(14.3,11.2)];
        [bars stroke];
        return YES;
    }];
    [mark setTemplate:YES]; menuItem.button.image=mark; menuItem.button.toolTip=@"MacAmp";
    [menuItem.button setAccessibilityLabel:@"MacAmp"];
    button=[NSButton buttonWithTitle:@"Enable Effects" target:self action:@selector(toggle:)];
    button.frame=NSMakeRect(323,351,139,36); button.bezelColor=NSColor.systemTealColor;
    button.keyEquivalent=@" ";
    NSTextField *outputLabel=label(@"Mac Output",NSMakeRect(24,302,122,23),14,NSFontWeightMedium);
    outputPicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(153,298,309,32) pullsDown:NO];
    outputPicker.target=self; outputPicker.action=@selector(selectWindowOutput:);
    [outputPicker setAccessibilityLabel:@"Mac audio output"];
    __weak Controller *weakSelf=self;
    outputListener=^(UInt32 count,const AudioObjectPropertyAddress *addresses) { [weakSelf refreshOutputs]; };
    for(const auto &addr:{outputDevicesAddress,defaultOutputAddress})
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,&addr,dispatch_get_main_queue(),outputListener);
    [self refreshOutputs];
    collections=[NSSegmentedControl segmentedControlWithLabels:@[@"Built-in", @"Bonus"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeCollection:)];
    collections.frame=NSMakeRect(19,251,177,30);
    [collections setAccessibilityLabel:@"Preset collection"];
    profiles=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(211,251,251,30) pullsDown:NO];
    profiles.target=self; profiles.action=@selector(changeProfile:);
    [profiles setAccessibilityLabel:@"Choose an audio preset"];

    NSBox *card=[[NSBox alloc] initWithFrame:NSMakeRect(22,79,438,158)];
    card.boxType=NSBoxCustom; card.titlePosition=NSNoTitle; card.cornerRadius=12;
    card.fillColor=NSColor.controlBackgroundColor; card.borderColor=NSColor.separatorColor;
    card.borderWidth=1; card.contentViewMargins=NSZeroSize;
    presetTitle=label(@"",NSMakeRect(16,111,398,31),23,NSFontWeightSemibold);
    strengthLabel=label(@"",NSMakeRect(17,84,400,20),12,NSFontWeightMedium);
    strengthLabel.textColor=NSColor.secondaryLabelColor;
    curve=[[PresetCurve alloc] initWithFrame:NSMakeRect(10,14,415,65)];
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"IntensityPercent":@100}];
    NSInteger saved=std::clamp<NSInteger>([defaults integerForKey:@"IntensityPercent"],50,150);
    slider=[NSSlider sliderWithValue:saved minValue:50 maxValue:150 target:self action:@selector(changeStrength:)];
    slider.frame=NSMakeRect(16,35,401,28); slider.continuous=YES;
    [slider setAccessibilityLabel:@"Effect intensity"];
    [self changeStrength:slider];
    for(NSView *v in @[presetTitle,strengthLabel,curve,slider]) [card.contentView addSubview:v];
    status=[NSTextField wrappingLabelWithString:@"Effects are off. You’re hearing the original audio."];
    status.font=[NSFont systemFontOfSize:12]; status.textColor=NSColor.secondaryLabelColor;
    status.frame=NSMakeRect(24,12,252,48);
    compare=[NSButton buttonWithTitle:@"Previous Preset" target:self action:@selector(compare:)];
    compare.frame=NSMakeRect(277,22,185,30);
    compare.image=[NSImage imageWithSystemSymbolName:@"arrow.left.arrow.right" accessibilityDescription:nil];
    compare.imagePosition=NSImageLeading;
    for(NSView *v in @[title,icon,button,outputLabel,outputPicker,collections,profiles,card,status,compare]) [view addSubview:v];
    NSInteger split=builtInNames().count+1;
    lastSelection[1]=split; prior=-1;
    NSString *savedProfile=[defaults stringForKey:@"SelectedPreset"];
    NSInteger initial=0;
    if([savedProfile hasPrefix:@"FxSound · "]) {
        NSUInteger idx=[factoryNames() indexOfObject:[savedProfile substringFromIndex:[@"FxSound · " length]]];
        if(idx!=NSNotFound) initial=idx+1;
    }
    [self displayProfile:initial];
    menuItem.button.target=self;
    [menuItem.button sendActionOn:NSEventMaskLeftMouseDown];
    menuItem.button.action=@selector(toggleControls:);
    [window center];
}
-(void)displayProfile:(NSInteger)index {
    NSInteger split=1+builtInNames().count;
    NSInteger group=index>=split;
    lastSelection[group]=index; collections.selectedSegment=group;
    [profiles removeAllItems];
    if(group) [profiles addItemsWithTitles:bonusNames()];
    else { [profiles addItemWithTitle:@"Prototype"]; [profiles addItemsWithTitles:builtInNames()]; }
    [profiles selectItemAtIndex:group ? index-split : index];
    NSString *name=profiles.titleOfSelectedItem;
    presetTitle.stringValue=name;
    slider.hidden=index!=0; curve.hidden=index==0;
    if(index) [curve showPreset:name];
    strengthLabel.stringValue=index ? @"10-band equalizer" :
        [NSString stringWithFormat:@"Effect intensity   %d%%",engine.intensity.load()];
    compare.enabled=prior>=0;
    compare.toolTip=prior<0 ? @"Choose two presets to compare them." :
        (prior==0 ? @"Prototype" : factoryNames()[prior-1]);
    engine.select((int)index);
    quickPreset.title=name;
    [NSUserDefaults.standardUserDefaults setObject:index ? [@"FxSound · " stringByAppendingString:name] : name forKey:@"SelectedPreset"];
}
-(void)switchTo:(NSInteger)index {
    if(index==engine.selected) return;
    prior=engine.selected;
    [self displayProfile:index];
}
-(void)compare:(id)sender { if(prior>=0) [self switchTo:prior]; }
-(void)changeCollection:(NSSegmentedControl*)sender { [self switchTo:lastSelection[sender.selectedSegment]]; }
-(void)changeProfile:(NSPopUpButton*)sender {
    [self switchTo:sender.indexOfSelectedItem+(collections.selectedSegment ? builtInNames().count+1 : 0)];
}
-(void)changeStrength:(NSSlider*)sender {
    int percent = (int)lround(sender.doubleValue);
    engine.intensity.store(percent, std::memory_order_relaxed);
    strengthLabel.stringValue = [NSString stringWithFormat:@"Effect intensity   %d%%", percent];
    [NSUserDefaults.standardUserDefaults setInteger:percent forKey:@"IntensityPercent"];
}
-(void)refreshOutputs {
    AudioDeviceID current=0;
    readProp(kAudioObjectSystemObject,defaultOutputAddress.mSelector,&current,sizeof(current));
    UInt32 bytes=0;
    OSStatus error=AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&outputDevicesAddress,0,nullptr,&bytes);
    std::vector<AudioDeviceID> devices(bytes/sizeof(AudioDeviceID));
    if(!error && bytes) error=AudioObjectGetPropertyData(kAudioObjectSystemObject,&outputDevicesAddress,0,nullptr,&bytes,devices.data());
    if(error) devices.clear(); else devices.resize(bytes/sizeof(AudioDeviceID));
    NSMenu *choices=[[NSMenu alloc] initWithTitle:@"Mac Output"];
    for(AudioDeviceID device:devices) {
        UInt32 selectable=0,alive=0,hidden=0;
        if(device==engine.aggregate ||
           readProp(device,kAudioDevicePropertyDeviceCanBeDefaultDevice,&selectable,sizeof(selectable),kAudioObjectPropertyScopeOutput) || !selectable ||
           readProp(device,kAudioDevicePropertyDeviceIsAlive,&alive,sizeof(alive)) || !alive) continue;
        if(!readProp(device,kAudioDevicePropertyIsHidden,&hidden,sizeof(hidden)) && hidden) continue;
        CFStringRef name=nullptr;
        if(readProp(device,kAudioObjectPropertyName,&name,sizeof(name)) || !name) continue;
        NSMenuItem *item=[choices addItemWithTitle:CFBridgingRelease(name) action:nil keyEquivalent:@""];
        item.tag=device;
    }
    outputPicker.menu=choices;
    [outputPicker selectItem:[choices itemWithTag:current]];
    outputPicker.enabled=choices.numberOfItems>0;
    if(!choices.numberOfItems) [outputPicker addItemWithTitle:@"No output available"];
    quickOutput.title=outputPicker.titleOfSelectedItem ?: @"Choose an output";
    quickOutput.enabled=outputPicker.enabled;
    if(choiceScroll && choosingOutput) {
        if(quickOutput.enabled) [self populateChoices];
        else [self closeChoices];
    }
}
-(void)setMacOutput:(AudioDeviceID)device {
    OSStatus error=AudioObjectSetPropertyData(kAudioObjectSystemObject,&defaultOutputAddress,0,nullptr,sizeof(device),&device);
    if(error) {
        NSString *message=[NSString stringWithFormat:@"Could not switch the Mac output (%d).",(int)error];
        status.stringValue=message; [self showWindow:nil];
    }
    [self refreshOutputs];
}
-(void)selectWindowOutput:(NSPopUpButton*)sender { [self setMacOutput:(AudioDeviceID)sender.selectedItem.tag]; }
-(void)createControlsPanel {
    controlsPanel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,316,189)
        styleMask:NSWindowStyleMaskNonactivatingPanel|NSWindowStyleMaskTitled|NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    controlsPanel.title=@"MacAmp Controls";
    controlsPanel.titlebarAppearsTransparent=YES;
    controlsPanel.titleVisibility=NSWindowTitleHidden;
    controlsPanel.hidesOnDeactivate=NO;
    controlsPanel.level=NSStatusWindowLevel;
    controlsPanel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorCanJoinAllApplications;
    NSView *view=controlsPanel.contentView;
    [view addSubview:label(@"MacAmp",NSMakeRect(15,147,147,26),17,NSFontWeightSemibold)];
    powerCommand=[NSButton buttonWithTitle:button.title target:self action:@selector(toggle:)];
    powerCommand.frame=NSMakeRect(165,144,139,32);
    [view addSubview:powerCommand];
    quickOutput=[PanelButton buttonWithTitle:@"Output" target:self action:@selector(openChoices:)];
    quickPreset=[PanelButton buttonWithTitle:@"Preset" target:self action:@selector(openChoices:)];
    for(NSButton *picker in @[quickOutput,quickPreset]) {
        BOOL output=picker==quickOutput;
        CGFloat y=output ? 101 : 65;
        NSString *caption=output ? @"Mac Output" : @"Preset";
        picker.frame=NSMakeRect(98,y,204,28);
        picker.image=[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil];
        picker.imagePosition=NSImageTrailing;
        [picker setAccessibilityLabel:caption];
        [view addSubview:label(caption,NSMakeRect(15,y+2,80,21),13,NSFontWeightMedium)];
        [view addSubview:picker];
    }
    view.autoresizesSubviews=NO;
    NSButton *open=[NSButton buttonWithTitle:@"Open MacAmp" target:self action:@selector(showWindow:)];
    open.frame=NSMakeRect(10,15,156,32); [view addSubview:open];
    NSButton *quit=[NSButton buttonWithTitle:@"Quit" target:NSApp action:@selector(terminate:)];
    quit.frame=NSMakeRect(226,15,78,32); [view addSubview:quit];
}
// Insert the list under its field while keeping the panel anchored to the menu bar.
-(void)setChoiceHeight:(CGFloat)height {
    CGFloat delta=height-expandedHeight;
    if(delta==0) return;
    NSButton *field=choosingOutput ? quickOutput : quickPreset;
    CGFloat split=NSMinY(field.frame);
    for(NSView *view in controlsPanel.contentView.subviews) {
        NSPoint origin=view.frame.origin;
        if(view!=choiceScroll && origin.y>=split)
            [view setFrameOrigin:NSMakePoint(origin.x,origin.y+delta)];
    }
    NSRect frame=controlsPanel.frame;
    frame.origin.y-=delta; frame.size.height+=delta;
    [controlsPanel setFrame:frame display:YES];
    expandedHeight=height;
}
-(void)closeChoices {
    if(!choiceScroll) return;
    [choiceScroll removeFromSuperview];
    choiceScroll=nil;
    [self setChoiceHeight:0];
    (choosingOutput ? quickOutput : quickPreset).image=[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil];
}
-(void)openChoices:(NSButton*)sender {
    BOOL same=choiceScroll && choosingOutput==(sender==quickOutput);
    [self closeChoices];
    if(same) return;
    choosingOutput=sender==quickOutput;
    sender.image=[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:nil];
    choiceScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];
    choiceScroll.hasVerticalScroller=YES;
    choiceScroll.autohidesScrollers=YES;
    choiceScroll.borderType=NSBezelBorder;
    [controlsPanel.contentView addSubview:choiceScroll];
    [self populateChoices];
}
-(void)populateChoices {
    NSButton *field=choosingOutput ? quickOutput : quickPreset;
    CGFloat width=NSWidth(field.frame)-21;
    ChoiceRows *rows=[[ChoiceRows alloc] initWithFrame:NSMakeRect(0,0,width,1)];
    NSInteger selected=choosingOutput ? outputPicker.selectedTag : engine.selected;
    CGFloat y=0, selectedY=0;
    auto addChoice = [&](NSString *title,NSInteger tag) {
        PanelButton *row=[PanelButton buttonWithTitle:title target:self action:@selector(pickChoice:)];
        row.tag=tag; row.alignment=NSTextAlignmentLeft; row.bordered=NO;
        row.frame=NSMakeRect(4,y,width-8,26);
        if(tag==selected) {
            row.image=[NSImage imageWithSystemSymbolName:@"checkmark" accessibilityDescription:@"Selected"];
            row.imagePosition=NSImageLeading; selectedY=y;
        }
        [rows addSubview:row]; y+=27;
    };
    if(choosingOutput) {
        for(NSMenuItem *item in outputPicker.itemArray) if(item.tag) addChoice(item.title,item.tag);
    } else {
        NSInteger index=0;
        for(NSString *group in @[@"Built-in",@"Bonus"]) {
            [rows addSubview:label(group,NSMakeRect(5,y,width-9,22),12,NSFontWeightSemibold)]; y+=22;
            NSArray *names=index ? bonusNames() : [@[@"Prototype"] arrayByAddingObjectsFromArray:builtInNames()];
            for(NSString *name in names) addChoice(name,index++);
        }
    }
    CGFloat height=std::min(y+2,161.);
    [self setChoiceHeight:height+4];
    choiceScroll.frame=NSMakeRect(NSMinX(field.frame),NSMinY(field.frame)-height-2,NSWidth(field.frame),height);
    [rows setFrameSize:NSMakeSize(width,y)];
    choiceScroll.documentView=rows;
    [rows scrollRectToVisible:NSMakeRect(0,selectedY,100,26)];
}
-(void)pickChoice:(NSButton*)row {
    NSInteger tag=row.tag;
    [self closeChoices];
    if(choosingOutput) [self setMacOutput:(AudioDeviceID)tag];
    else [self switchTo:tag];
}
-(void)hideControls {
    if(outsideClick) { [NSEvent removeMonitor:outsideClick]; outsideClick=nil; }
    if(localClick) { [NSEvent removeMonitor:localClick]; localClick=nil; }
    [controlsPanel orderOut:nil];
}
-(void)toggleControls:(id)sender {
    NSEvent *event=NSApp.currentEvent;
    if(event.type==NSEventTypeLeftMouseDown) {
        lastIconDown=event.timestamp;
        if(lastOutsideDown==lastIconDown && lastIconDown>0) return;
    }
    if(controlsPanel.visible) { [self hideControls]; return; }
    if(!controlsPanel) [self createControlsPanel];
    [self hideControls];
    [self closeChoices];
    [self refreshOutputs]; quickPreset.title=profiles.titleOfSelectedItem;
    powerCommand.title=button.title;
    NSPoint cursor=NSEvent.mouseLocation;
    NSScreen *screen=menuItem.button.window.screen ?: NSScreen.mainScreen;
    for(NSScreen *candidate in NSScreen.screens) if(NSPointInRect(cursor,candidate.frame)) { screen=candidate; break; }
    NSRect display=screen.frame;
    CGFloat width=NSWidth(controlsPanel.frame);
    CGFloat x=std::clamp(cursor.x-width/2,NSMinX(display)+4,NSMaxX(display)-width-4);
    CGFloat inset=std::max(NSStatusBar.systemStatusBar.thickness,screen.safeAreaInsets.top);
    [controlsPanel setFrameTopLeftPoint:NSMakePoint(x,NSMaxY(display)-inset-3)];
    [controlsPanel orderFrontRegardless];
    NSEventMask clicks=NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown;
    __weak Controller *weakSelf=self;
    outsideClick=[NSEvent addGlobalMonitorForEventsMatchingMask:clicks handler:^(NSEvent *event){
        Controller *owner=weakSelf;
        if(!owner) return;
        // The menu bar host can also deliver this press to our status button.
        NSStatusBarButton *icon=owner->menuItem.button;
        NSRect iconRect=[icon.window convertRectToScreen:[icon convertRect:icon.bounds toView:nil]];
        if(event.type==NSEventTypeLeftMouseDown &&
           (event.timestamp==owner->lastIconDown || NSPointInRect(NSEvent.mouseLocation,iconRect))) return;
        owner->lastOutsideDown=event.timestamp;
        [owner hideControls];
    }];
    localClick=[NSEvent addLocalMonitorForEventsMatchingMask:clicks handler:^NSEvent*(NSEvent *event){
        Controller *owner=weakSelf;
        if(owner && event.window==owner->window) [owner hideControls];
        return event;
    }];
}
-(void)showWindow:(id)sender {
    [self hideControls];
    if(window.isMiniaturized) [window deminiaturize:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
}
-(BOOL)applicationShouldHandleReopen:(NSApplication*)app hasVisibleWindows:(BOOL)visible {
    [self showWindow:nil]; return NO;
}
-(void)connected {
    CFStringRef name=nullptr;
    if(!readProp(engine.device,kAudioObjectPropertyName,&name,sizeof(name)) && name)
        outputName=CFBridgingRelease(name);
    else outputName=@"Mac Output";
    quiet=0; retryTicks=0;
    status.stringValue=[@"Effects on · " stringByAppendingString:outputName];
    menuItem.button.toolTip=status.stringValue;
}
-(void)off:(NSString*)message {
    [timer invalidate]; timer=nil; engine.stop(); status.stringValue=message; button.title=@"Enable Effects";
    powerCommand.title=button.title;
    menuItem.button.toolTip=@"MacAmp · Effects off";
}
-(void)toggle:(id)sender {
    if(timer) { [self off:@"Effects are off. You’re hearing the original audio."]; return; }
    NSString *error=engine.start();
    if(error) { [self off:error]; return; }
    [self connected]; button.title=@"Disable Effects";
    powerCommand.title=button.title;
    timer=[NSTimer timerWithTimeInterval:.5 target:self selector:@selector(check:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
-(void)check:(id)sender {
    delete engine.retired.exchange(nullptr);
    AudioObjectID current=0; double rate=0;
    bool ready=!readProp(1,kAudioHardwarePropertyDefaultOutputDevice,&current,sizeof(current)) && current &&
        !readProp(current,kAudioDevicePropertyNominalSampleRate,&rate,sizeof(rate)) && rate>0;
    if(engine.proc && (!ready || engine.invalid || current!=engine.device || rate!=engine.rate)) {
        engine.stop(); retryTicks=0;
        status.stringValue=@"Switching to the current Mac output…"; menuItem.button.toolTip=status.stringValue;
        return;
    }
    if(!engine.proc) {
        if(!ready) return;
        if(retryTicks && current==engine.device) { --retryTicks; return; }
        NSString *error=engine.start();
        if(error) {
            engine.stop(); retryTicks=5;
            status.stringValue=[@"Retrying · " stringByAppendingString:error];
        } else [self connected];
        return;
    }
    if(engine.signal.exchange(false)) {
        quiet=0; status.stringValue=[@"Effects on · " stringByAppendingString:outputName];
    } else if(++quiet==6) status.stringValue=[@"Waiting for audio · " stringByAppendingString:outputName];
}
-(BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app { return NO; }
-(void)applicationWillTerminate:(NSNotification*)note {
    for(const auto &addr:{outputDevicesAddress,defaultOutputAddress})
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,&addr,dispatch_get_main_queue(),outputListener);
    engine.stop();
}
@end

int main(int argc,const char **argv) {
    if(argc==2 && !strcmp(argv[1],"--test-dsp")) {
        for(double rate : {44100.,48000.,96000.}) {
            double previous = 0;
            for (float level : {.5f, 1.f, 1.5f}) {
                Effect e; e.configure(rate,level); double input=0,output=0;
                for(int i=0;i<int(rate);i++) {
                    float l=.08f*sinf(2*M_PI*440*i/rate),r=l; input+=l*l;
                    e.frame(l,r,level); if(!std::isfinite(l)||l!=r) return 1; output+=l*l;
                }
                if(output<=input || output<=previous) return 1;
                previous=output;
                printf("%.0f Hz, %.0f%%: quiet tone %+.2f dB\n",rate,100*level,10*log10(output/input));
                for(int i=0;i<1000;i++) { float l=1,r=-1; e.frame(l,r,level); if(!(fabsf(l)<=.981f && fabsf(r)<=.981f)) return 1; }
            }
        }
        NSMutableArray *bank=[NSMutableArray array];
        for(double rate : {44100.,48000.,96000.}) {
            NSString *error=loadFactory(bank,rate);
            if(error) { fprintf(stderr,"%s\n",error.UTF8String); return 1; }
            for(NSDictionary *settings in bank) {
                FactoryEffect preset; preset.configure(settings,rate);
                double energy=0;
                for(int i=0;i<rate;++i) {
                    float l=.9f*sinf(.11f*i), r=.65f*cosf(.18f*i);
                    preset.frame(l,r);
                    if(!(fabsf(l)<=.967f && fabsf(r)<=.967f)) return 1;
                    energy+=l*l+r*r;
                }
                if(energy<1) return 1;
            }
        }
        puts("Factory presets passed at three sample rates.");
        return 0;
    }
    @autoreleasepool {
        NSApplication *app=[NSApplication sharedApplication]; __attribute__((objc_precise_lifetime)) Controller *controller=[Controller new];
        app.delegate=controller; [app run];
        (void)controller;
    }
    return 0;
}
