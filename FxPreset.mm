// Derived from the FxSound DSP tutorial, copyright FxSound LLC. See FxSound/LICENSE.
#import <JavaScriptCore/JavaScriptCore.h>
#include <array>
#include <vector>
#include <cmath>
#include <algorithm>

#include "Ambience.hpp"

static NSArray<NSString *> *builtInNames() { return @[@"General", @"Music", @"Voice", @"Volume Boost", @"Gaming", @"Classic Processing", @"Light Processing", @"Bass Boost", @"Streaming Video", @"Movies", @"TV", @"Transcription", @"Default"]; }

static NSArray<NSString *> *bonusNames() {
    return @[@"70's", @"80's", @"Alternative Rock", @"Classic Rock", @"Classical", @"Jazz",
             @"Metal", @"Modern Country", @"Modern Rock", @"Pop", @"R&B", @"Trap"];
}
static NSArray<NSString *> *factoryNames() { return [builtInNames() arrayByAddingObjectsFromArray:bonusNames()]; }

struct Section {
    float b0,b1,b2,a2, z1[2]{}, z2[2]{};
    Section(NSDictionary *p) : b0([p[@"b0"] floatValue]), b1([p[@"b1"] floatValue]),
        b2([p[@"b2"] floatValue]), a2([p[@"a2"] floatValue]) {}
    float run(float x,int c) {
        float y = z1[c] + b0*x + 1.e-30f;
        z1[c] = (x-y)*b1 + z2[c];
        z2[c] = b2*x - a2*y;
        return y;
    }
};

struct PeakLimiter {
    std::vector<float> delay;
    size_t cursor{};
    int ramp{};
    float maximum{}, delta{}, envelope{};
    float run(float sample,float beta,float ceiling) {
        float delayed = delay[cursor];
        delay[cursor] = sample;
        if (++cursor == delay.size()) cursor = 0;
        float level = fabsf(sample);
        if (ramp) {
            envelope = std::max(envelope,fabsf(delayed));
            if (level > maximum) {
                maximum = level; ramp = int(delay.size());
                delta = std::max(delta,(level-envelope)/(ramp+1));
            } else --ramp;
            envelope += delta;
        } else {
            envelope = std::max(envelope*beta + 1.e-24f,fabsf(delayed));
            if (level > envelope) {
                maximum = level; ramp = int(delay.size());
                delta = (level-envelope)/(ramp+1);
                envelope += delta;
            }
        }
        return envelope > ceiling ? delayed*ceiling/envelope : delayed;
    }
};

struct FactoryEffect {
    std::vector<Section> eq;
    Ambience ambience;
    Section bass{nil};
    bool bassOn{}, wideOn{}, fidelityOn{};
    float drive{},hpGain{},a1{},a0{},side{},mid{},gain{},beta{},ceiling{},target{};
    float out1[2]{},out2[2]{},in1[2]{},in2[2]{};
    double level{},levelGain{},levelDecay{};
    PeakLimiter limiter[2];
    void configure(NSDictionary *p,double rate) {
        *this = FactoryEffect{};
        for (NSDictionary *band in p[@"sections"]) eq.emplace_back(band);
        NSDictionary *a=p[@"aural"], *w=p[@"wide"], *b=p[@"bass"], *m=p[@"maxi"];
        ambience.configure(p[@"lex"],rate);
        fidelityOn=[a[@"on"] boolValue];
        drive=[a[@"drive"] floatValue]; hpGain=[a[@"gain"] floatValue];
        a1=[a[@"a1"] floatValue]; a0=[a[@"a0"] floatValue];
        wideOn=[w[@"on"] boolValue];
        float intensity=[w[@"intensity"] floatValue];
        side=1+3.*intensity; mid=1-.3*intensity;
        bassOn=[b[@"on"] boolValue]; bass=Section(b);
        gain=[m[@"gainBoost"] floatValue]; beta=[m[@"releaseBeta"] floatValue];
        ceiling=[m[@"maxOutput"] floatValue]; target=[m[@"targetLevel"] floatValue];
        for(auto &ch : limiter) ch.delay.resize(std::max(1,[m[@"maxDelay"] intValue]));
        double c=cos(6.283185*.1/rate);
        double decay=2-c-sqrt(c*c-4*c+3);
        levelGain=float(1-decay); levelDecay=float(decay);
    }
    void frame(float &left,float &right) {
        float x[2]={left,right};
        for(int c=0;c<2;++c) {
            for(auto &band:eq) x[c]=band.run(x[c],c);
            if(!fidelityOn) continue;
            float high=out1[c]*a1+out2[c]*a0+((x[c]+1.e-30f)-2*in1[c]+in2[c])*hpGain;
            out2[c]=out1[c]; out1[c]=high; in2[c]=in1[c]; in1[c]=x[c];
            x[c]=(x[c]+1.5f*float(sin(double(high*drive))))*.377953f+.622047f*x[c];
        }
        ambience.frame(x[0],x[1]);
        if(wideOn) {
            float mono=(x[0]+x[1])*.5f;
            for(float &v:x) v=mono*mid+(v-mono)*side;
        }
        if(bassOn) for(int c=0;c<2;++c) x[c]=bass.run(x[c],c);
        level=level*levelDecay+(x[0]*x[0])*levelGain;
        float rms=sqrt(level);
        float boost=gain*rms>target ? std::max(1.06f,target/rms) : gain;
        left=limiter[0].run(boost*ceiling*x[0],beta,ceiling);
        right=limiter[1].run(boost*ceiling*x[1],beta,ceiling);
    }
};

static NSString *loadFactory(NSMutableArray<NSDictionary *> *parameters,double rate) {
    JSContext *context=[JSContext new];
    NSString *folder=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"FxSound"];
    for (NSString *script in @[@"sos.js",@"controls.js",@"load.js"]) {
        NSString *source=[NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:script]
                                                   encoding:NSUTF8StringEncoding error:nil];
        if (!source) return @"File DSP FxSound tidak ditemukan.";
        [context evaluateScript:source];
        if(context.exception) return context.exception.toString;
    }
    NSArray *names=factoryNames();
    [parameters removeAllObjects];
    for(NSUInteger i=0;i<names.count;++i) {
        NSString *file=[names[i] stringByAppendingPathExtension:@"fac"];
        NSString *text=[NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:file]
                                                 encoding:NSUTF8StringEncoding error:nil];
        if(!text) return @"File preset FxSound tidak ditemukan.";
        NSDictionary *params=[[context[@"readPreset"] callWithArguments:@[text,@(rate)]] toDictionary];
        if(!params || context.exception) return @"Preset FxSound gagal dimuat.";
        [parameters addObject:params];
    }
    return nil;
}
