// Parse the bundled CLASS1 version 9 presets. Calculate parameters before audio starts.
function readPreset(text, rate) {
    const lines = text.trim().split(/\r?\n/);
    const fields = new Map();
    const bands = [];
    let frequency;
    for (const line of lines) {
        const [raw, key] = line.trim().split(/\s*:\s*/);
        if (!key) continue;
        const value = Number(raw);
        fields.set(key, value);
        if (key === "CF") frequency = value;
        if (key === "Boost/Cut") bands.push([frequency, value]);
    }
    function field(key) {
        const x = fields.get(key);
        if (!Number.isFinite(x)) throw Error(key);
        return x;
    }
    function slider(main, flag) {
        return field("Integer[" + flag + "]") ? field("Main " + main) * 10 / 127 : 0;
    }
    if (field("Version") !== 9 || bands.length !== 10)
        throw Error("Unsupported preset");
    const settings = {ambience:slider(3,2), fidelity:slider(0,0), surround:slider(1,1), dynamicBoost:slider(4,3), bass:slider(5,4)};
    const p = FxDsp.controls.effectParams(settings, rate);
    const q = FxDsp.sos.bandQ(1);
    p.sections = bands.filter(([hz, db]) => field("On/Off Flag") && db && hz*2 < rate)
        .map(([hz, db]) => FxDsp.sos.calcParametric(rate, hz, db, q));
    return p;
}
