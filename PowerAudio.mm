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
            return @"Output audio tidak tersedia.";
        CFStringRef uid=nullptr;
        if(readProp(device,kAudioDevicePropertyDeviceUID,&uid,sizeof(uid)) || !uid) return @"Gagal membaca perangkat output.";
        NSString *outputUID=CFBridgingRelease(uid);
        if(readProp(device,kAudioDevicePropertyNominalSampleRate,&rate,sizeof(rate)) || !(rate>0)) return @"Sample rate tidak tersedia.";
        parameters=[NSMutableArray array];
        NSString *error=loadFactory(parameters,rate);
        if(error) return error;
        active=prepare(selected); step=float(1/(.020*rate));
        pid_t pid=getpid(); AudioObjectID me=0; UInt32 size=sizeof(me);
        AudioObjectPropertyAddress addr{kAudioHardwarePropertyTranslatePIDToProcessObject,kAudioObjectPropertyScopeGlobal,0};
        if(AudioObjectGetPropertyData(1,&addr,sizeof(pid),&pid,&size,&me) || !me) return @"Gagal mengenali proses audio aplikasi.";
        UInt32 transport=0;
        readProp(device,kAudioDevicePropertyTransportType,&transport,sizeof(transport));
        bool bluetooth=transport==kAudioDeviceTransportTypeBluetooth || transport==kAudioDeviceTransportTypeBluetoothLE;
        // A device-stream tap inherits the headset clock and format. A global mix can use a different rate.
        CATapDescription *desc=bluetooth
            ? [[CATapDescription alloc] initExcludingProcesses:@[@(me)] andDeviceUID:outputUID withStream:0]
            : [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[@(me)]];
        desc.name=@"Power Audio"; [desc setPrivate:YES]; desc.muteBehavior=CATapMutedWhenTapped;
        OSStatus s=AudioHardwareCreateProcessTap(desc,&tap);
        if(s) return [NSString stringWithFormat:@"Tap gagal (%d). Periksa izin audio sistem.", (int)s];
        NSDictionary *config=@{@kAudioAggregateDeviceNameKey:@"Power Audio Monitor",
            @kAudioAggregateDeviceUIDKey:NSUUID.UUID.UUIDString, @kAudioAggregateDeviceIsPrivateKey:@YES,
            @kAudioAggregateDeviceMainSubDeviceKey:outputUID,
            @kAudioAggregateDeviceSubDeviceListKey:@[@{@kAudioSubDeviceUIDKey:outputUID}],
            @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:desc.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}],
            @kAudioAggregateDeviceTapAutoStartKey:@YES};
        s=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config,&aggregate);
        if(s) return [NSString stringWithFormat:@"Gagal membuka output (%d).",(int)s];
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
            return [NSString stringWithFormat:@"Format tap %.0f Hz (%u kanal), output %.0f Hz belum cocok.",f.mSampleRate,f.mChannelsPerFrame,rate];
        }
        s=AudioDeviceCreateIOProcID(aggregate,render,this,&proc);
        if(!s) s=AudioDeviceStart(aggregate,proc);
        return s ? [NSString stringWithFormat:@"Audio gagal dimulai (%d). Periksa izin audio sistem.",(int)s] : nil;
    }
};

#import "PresetCurve.mm"

static const AudioObjectPropertyAddress outputDevicesAddress{
    kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
static const AudioObjectPropertyAddress defaultOutputAddress{
    kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};

@interface Controller : NSObject <NSApplicationDelegate>
@end
@implementation Controller {
    NSWindow *window; NSButton *button; NSTextField *status; Engine engine;
    NSTimer *timer; NSUInteger quiet, retryTicks;
    NSStatusItem *menuItem; NSString *outputName;
    NSMenuItem *powerCommand;
    NSMenu *outputCommands;
    NSMutableArray<NSMenuItem *> *presetCommands;
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
    window.title=@"Power Audio"; window.releasedWhenClosed=NO;
    NSView *view=window.contentView;
    NSTextField *title=label(@"Power Audio",NSMakeRect(70,351,210,36),27,NSFontWeightBold);
    NSImage *art=[[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"PowerAudio" ofType:@"png"]];
    if (art) {
        NSApp.applicationIconImage=art;
        NSImageView *dockIcon=[NSImageView imageViewWithImage:art];
        dockIcon.imageScaling=NSImageScaleProportionallyUpOrDown;
        NSApp.dockTile.contentView=dockIcon;
        [NSApp.dockTile display];
    }
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
    [mark setTemplate:YES]; menuItem.button.image=mark; menuItem.button.toolTip=@"Power Audio";
    [menuItem.button setAccessibilityLabel:@"Power Audio"];
    button=[NSButton buttonWithTitle:@"Aktifkan efek" target:self action:@selector(toggle:)];
    button.frame=NSMakeRect(323,351,139,36); button.bezelColor=NSColor.systemTealColor;
    button.keyEquivalent=@" ";
    NSTextField *outputLabel=label(@"Output Mac",NSMakeRect(24,302,122,23),14,NSFontWeightMedium);
    outputPicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(153,298,309,32) pullsDown:NO];
    outputPicker.target=self; outputPicker.action=@selector(selectWindowOutput:);
    [outputPicker setAccessibilityLabel:@"Output suara Mac"];
    __weak Controller *weakSelf=self;
    outputListener=^(UInt32 count,const AudioObjectPropertyAddress *addresses) { [weakSelf refreshOutputs]; };
    for(const auto &addr:{outputDevicesAddress,defaultOutputAddress})
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,&addr,dispatch_get_main_queue(),outputListener);
    [self refreshOutputs];
    collections=[NSSegmentedControl segmentedControlWithLabels:@[@"Bawaan", @"Bonus"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeCollection:)];
    collections.frame=NSMakeRect(19,251,177,30);
    [collections setAccessibilityLabel:@"Koleksi preset"];
    profiles=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(211,251,251,30) pullsDown:NO];
    profiles.target=self; profiles.action=@selector(changeProfile:);
    [profiles setAccessibilityLabel:@"Pilih preset suara"];

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
    [slider setAccessibilityLabel:@"Intensitas efek"];
    [self changeStrength:slider];
    for(NSView *v in @[presetTitle,strengthLabel,curve,slider]) [card.contentView addSubview:v];
    status=[NSTextField wrappingLabelWithString:@"Efek mati. Kamu mendengar audio asli."];
    status.font=[NSFont systemFontOfSize:12]; status.textColor=NSColor.secondaryLabelColor;
    status.frame=NSMakeRect(24,12,252,48);
    compare=[NSButton buttonWithTitle:@"Preset sebelumnya" target:self action:@selector(compare:)];
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
    [self installStatusMenu];
    [window center]; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
-(void)displayProfile:(NSInteger)index {
    NSInteger split=1+builtInNames().count;
    NSInteger group=index>=split;
    lastSelection[group]=index; collections.selectedSegment=group;
    [profiles removeAllItems];
    if(group) [profiles addItemsWithTitles:bonusNames()];
    else { [profiles addItemWithTitle:@"Prototipe"]; [profiles addItemsWithTitles:builtInNames()]; }
    [profiles selectItemAtIndex:group ? index-split : index];
    NSString *name=profiles.titleOfSelectedItem;
    presetTitle.stringValue=name;
    slider.hidden=index!=0; curve.hidden=index==0;
    if(index) [curve showPreset:name];
    strengthLabel.stringValue=index ? @"Equalizer   ·   10 band" :
        [NSString stringWithFormat:@"Intensitas efek   %d%%",engine.intensity.load()];
    compare.enabled=prior>=0;
    compare.toolTip=prior<0 ? @"Pilih dua preset untuk membandingkan." :
        (prior==0 ? @"Prototipe" : factoryNames()[prior-1]);
    engine.select((int)index);
    for(NSMenuItem *item in presetCommands) item.state=item.tag==index ? NSControlStateValueOn : NSControlStateValueOff;
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
    strengthLabel.stringValue = [NSString stringWithFormat:@"Intensitas efek   %d%%", percent];
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
    NSMenu *choices=[[NSMenu alloc] initWithTitle:@"Output Mac"];
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
    if(!choices.numberOfItems) [outputPicker addItemWithTitle:@"Output tidak tersedia"];
    if(outputCommands) [self syncOutputCommands];
}
-(void)setMacOutput:(AudioDeviceID)device {
    OSStatus error=AudioObjectSetPropertyData(kAudioObjectSystemObject,&defaultOutputAddress,0,nullptr,sizeof(device),&device);
    if(error) {
        NSString *message=[NSString stringWithFormat:@"Gagal mengganti output Mac (%d).",(int)error];
        status.stringValue=message; [self showWindow:nil];
    }
    [self refreshOutputs];
}
-(void)selectWindowOutput:(NSPopUpButton*)sender { [self setMacOutput:(AudioDeviceID)sender.selectedItem.tag]; }
-(void)selectMenuOutput:(NSMenuItem*)sender { [self setMacOutput:(AudioDeviceID)sender.tag]; }
-(void)syncOutputCommands {
    [outputCommands removeAllItems];
    for(NSMenuItem *choice in outputPicker.itemArray) {
        NSMenuItem *item=[outputCommands addItemWithTitle:choice.title action:choice.tag ? @selector(selectMenuOutput:) : nil keyEquivalent:@""];
        item.target=self; item.tag=choice.tag;
        item.state=choice.tag && choice==outputPicker.selectedItem ? NSControlStateValueOn : NSControlStateValueOff;
    }
}
-(void)installStatusMenu {
    // AppKit can present this populated menu from any Space, even on the first click.
    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"Power Audio"];
    powerCommand=[menu addItemWithTitle:button.title action:@selector(toggle:) keyEquivalent:@""];
    powerCommand.target=self;
    NSMenuItem *output=[menu addItemWithTitle:@"Output Mac" action:nil keyEquivalent:@""];
    outputCommands=[[NSMenu alloc] initWithTitle:@"Output Mac"];
    output.submenu=outputCommands;
    [self syncOutputCommands];
    presetCommands=[NSMutableArray array];
    [menu addItem:[NSMenuItem separatorItem]];
    NSInteger index=0;
    for(NSString *group in @[@"Bawaan",@"Bonus"]) {
        NSMenuItem *entry=[menu addItemWithTitle:group action:nil keyEquivalent:@""];
        NSMenu *list=[[NSMenu alloc] initWithTitle:group]; entry.submenu=list;
        NSArray *names=index ? bonusNames() : [@[@"Prototipe"] arrayByAddingObjectsFromArray:builtInNames()];
        for(NSString *name in names) {
            NSMenuItem *preset=[list addItemWithTitle:name action:@selector(menuPreset:) keyEquivalent:@""];
            [presetCommands addObject:preset];
            preset.tag=index++; preset.target=self;
            preset.state=preset.tag==engine.selected ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Buka Power Audio" action:@selector(showWindow:) keyEquivalent:@""].target=self;
    [menu addItemWithTitle:@"Keluar" action:@selector(terminate:) keyEquivalent:@""].target=NSApp;
    menuItem.menu=menu;
}
-(void)menuPreset:(NSMenuItem*)sender { [self switchTo:sender.tag]; }
-(void)showWindow:(id)sender { [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
-(BOOL)applicationShouldHandleReopen:(NSApplication*)app hasVisibleWindows:(BOOL)visible {
    [self showWindow:nil]; return NO;
}
-(void)connected {
    CFStringRef name=nullptr;
    if(!readProp(engine.device,kAudioObjectPropertyName,&name,sizeof(name)) && name)
        outputName=CFBridgingRelease(name);
    else outputName=@"Output Mac";
    quiet=0; retryTicks=0;
    status.stringValue=[@"Efek aktif · " stringByAppendingString:outputName];
    menuItem.button.toolTip=status.stringValue;
}
-(void)off:(NSString*)message {
    [timer invalidate]; timer=nil; engine.stop(); status.stringValue=message; button.title=@"Aktifkan efek";
    powerCommand.title=button.title;
    menuItem.button.toolTip=@"Power Audio · Efek mati";
}
-(void)toggle:(id)sender {
    if(timer) { [self off:@"Efek mati. Kamu mendengar audio asli."]; return; }
    NSString *error=engine.start();
    if(error) { [self off:error]; return; }
    [self connected]; button.title=@"Matikan efek";
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
        status.stringValue=@"Mengikuti output Mac…"; menuItem.button.toolTip=status.stringValue;
        return;
    }
    if(!engine.proc) {
        if(!ready) return;
        if(retryTicks && current==engine.device) { --retryTicks; return; }
        NSString *error=engine.start();
        if(error) {
            engine.stop(); retryTicks=5;
            status.stringValue=[@"Mencoba lagi · " stringByAppendingString:error];
        } else [self connected];
        return;
    }
    if(engine.signal.exchange(false)) {
        quiet=0; status.stringValue=[@"Efek aktif · " stringByAppendingString:outputName];
    } else if(++quiet==6) status.stringValue=[@"Menunggu audio · " stringByAppendingString:outputName];
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
        app.delegate=controller; [app setActivationPolicy:NSApplicationActivationPolicyRegular]; [app run];
        (void)controller;
    }
    return 0;
}
