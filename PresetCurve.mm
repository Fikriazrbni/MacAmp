// Static view of the ten EQ controls stored in the selected preset.
@interface PresetCurve : NSView
-(void)showPreset:(NSString*)name;
@end
@implementation PresetCurve {
    std::vector<NSPoint> bands;
}
-(void)showPreset:(NSString*)name {
    bands.clear();
    NSString *path=[NSBundle.mainBundle pathForResource:name ofType:@"fac" inDirectory:@"FxSound"];
    NSString *text=path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    double hz=0;
    for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if([line hasSuffix:@": CF"]) hz=line.doubleValue;
        if([line hasSuffix:@": Boost/Cut"] && hz>0) bands.push_back(NSMakePoint(hz,line.doubleValue));
    }
    self.needsDisplay=YES;
}
-(void)drawRect:(NSRect)dirty {
    NSRect rect=NSInsetRect(self.bounds,8,6);
    double mid=NSMidY(rect);
    [NSColor.separatorColor setStroke];
    NSBezierPath *grid=[NSBezierPath bezierPath];
    for(int i=-1;i<=1;++i) {
        double y=mid+i*rect.size.height*.4;
        [grid moveToPoint:NSMakePoint(NSMinX(rect),y)]; [grid lineToPoint:NSMakePoint(NSMaxX(rect),y)];
    }
    [grid stroke];
    [NSColor.systemTealColor setStroke]; [NSColor.systemTealColor setFill];
    NSBezierPath *path=[NSBezierPath bezierPath]; path.lineWidth=2;
    for(size_t i=0;i<bands.size();++i) {
        double x=NSMinX(rect)+std::clamp(log(bands[i].x/20)/log(1000.),0.,1.)*rect.size.width;
        double y=mid+std::clamp(bands[i].y/20.,-1.,1.)*rect.size.height*.5;
        NSPoint point=NSMakePoint(x,y);
        if(i) [path lineToPoint:point]; else [path moveToPoint:point];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-2.5,y-2.5,5,5)] fill];
    }
    [path stroke];
}
@end
