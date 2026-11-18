// Native stereo plate reverb adapted from FxSound's Lex DSP tutorial (AGPL-3.0).
#pragma once
struct Ambience {
    std::vector<float> memory;
    int cursor{}, pre{}, diffusion[4]{}, lattice5{}, lattice7{}, modulation{};
    std::array<int,4> delay1{}, delay3{};
    std::array<int,3> delay2{}, delay4{}, lattice6{}, lattice8{};
    float bandwidth{}, damping{}, decay{}, diffusionGain[4]{}, lateGain{}, tappedGain{}, wet{}, dry{};
    float filtered{}, damped1{}, damped2{}, feedback{};

    void configure(NSDictionary *p,float rate) {
        if (![p[@"on"] boolValue]) return;
        float roomRate = rate * [p[@"roomsize"] floatValue];
        auto length = [roomRate](double seconds){ return int(seconds * roomRate); };
        pre=int(rate*.100f);
        diffusion[0]=int(rate*.00477f); diffusion[1]=int(rate*.003595f);
        diffusion[2]=int(rate*.01273f); diffusion[3]=int(rate*.00931f);
        modulation=int(rate*.002f)+1;
        lattice5=length(.0226); lattice7=length(.0305);
        delay1={length(.0101),length(.0669),length(.1219),length(.1496)};
        delay2={length(.0358),length(.0898),length(.125)};
        delay3={length(.0101),length(.0709),length(.0999),length(.1417)};
        delay4={length(.004065),length(.0671),length(.1063)};
        lattice6={length(.00628),length(.04126),length(.0605)};
        lattice8={length(.01125),length(.0643),length(.0892)};
        int size=pre+lattice5+lattice7+2*modulation+delay1.back()+delay2.back()
                +delay3.back()+delay4.back()+lattice6.back()+lattice8.back();
        for(int n:diffusion) size+=n;
        memory.resize(size);
        bandwidth=[p[@"bandwidth"] floatValue]; damping=[p[@"damping"] floatValue];
        decay=[p[@"decay"] floatValue]; lateGain=[p[@"lat5"] floatValue];
        tappedGain=[p[@"lat6"] floatValue]; wet=[p[@"wet"] floatValue]; dry=[p[@"dry"] floatValue];
        diffusionGain[0]=diffusionGain[1]=[p[@"lat1"] floatValue];
        diffusionGain[2]=diffusionGain[3]=[p[@"lat3"] floatValue];
    }
    void advance(int n) {
        cursor+=n;
        if(cursor>=int(memory.size())) cursor-=int(memory.size());
    }
    float tap(int back) const {
        int pos=cursor-back;
        return memory[pos<0 ? pos+int(memory.size()) : pos];
    }
    float exchange(float sample) {
        float next=memory[cursor]; memory[cursor]=sample; return next;
    }
    void frame(float &left,float &right) {
        if(memory.empty()) return;
        left+=1.e-36f; right+=1.e-36f;
        advance(pre+1);
        float input=tap(1), next=exchange(left+right);
        filtered=input*(1-bandwidth)+bandwidth*filtered;
        auto diffuse=[&](float value,int delay,float coefficient) {
            advance(delay);
            float delayed=next, written=value-coefficient*delayed;
            next=exchange(written);
            return delayed+coefficient*written;
        };
        auto late=[&](float value,int delay) {
            advance(delay+modulation);
            float delayed=tap(delay), written=value+lateGain*delayed;
            next=exchange(written);
            return delayed-lateGain*written;
        };
        float early=filtered;
        for(int i=0;i<4;++i) early=diffuse(early,diffusion[i],diffusionGain[i]);
        float value=late(early+decay*feedback,lattice5);
        advance(delay1.back());
        float delayed=next; next=exchange(value);
        float l=-tap(delay1[1]), r=tap(delay1[0])+tap(delay1[2]);
        damped1=delayed*(1-damping)+damping*damped1;
        value=diffuse(damped1*decay,lattice6.back(),tappedGain);
        l-=tap(lattice6[0]); r-=tap(lattice6[1]);
        advance(delay2.back()); delayed=next; memory[cursor]=value;
        l-=tap(delay2[0]); r+=tap(delay2[1]);
        value=late(early+decay*delayed,lattice7);
        advance(delay3.back()); delayed=next; next=exchange(value);
        l+=tap(delay3[0])+tap(delay3[2]); r-=tap(delay3[1]);
        damped2=delayed*(1-damping)+damping*damped2;
        value=diffuse(damped2*decay,lattice8.back(),tappedGain);
        l-=tap(lattice8[1]); r-=tap(lattice8[0]);
        advance(delay4.back()); feedback=next; memory[cursor]=value;
        l+=tap(delay4[1]); r-=tap(delay4[0]);
        left=l*.3f*wet+dry*left; right=r*.3f*wet+dry*right;
    }
};
