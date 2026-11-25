import numpy as np, wave, sys
SR = 44100

def env(n, attack, tau, sr=SR):
    t = np.arange(n) / sr
    a = np.clip(t / attack, 0, 1); a = 0.5 - 0.5 * np.cos(np.pi * a)      # σύντομο, απαλό attack
    r = np.ones(n); k = min(n, int(.5 * sr)); r[-k:] = 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, k))   # ομαλό σβήσιμο
    return a * np.exp(-t / tau) * r

def rhodes(f, dur, tau, amp=1.0):
    """Απαλό FM «electric piano/βιμπράφωνο»: φωτεινό στην αρχή, γίνεται καθαρό ημίτονο."""
    n = int(dur * SR); t = np.arange(n) / SR
    idx = 1.1 * np.exp(-t / 0.22)                       # φωτεινότητα που σβήνει γρήγορα
    out = np.zeros((n, 2))
    for det, pan, a in [(0.0, 0.5, 1.0), (+1.2, 0.3, .28), (-1.2, 0.7, .28)]:   # ελαφρύ chorus
        ff = f * 2 ** (det / 1200)
        y = np.sin(2 * np.pi * ff * t + idx * np.sin(2 * np.pi * ff * t))
        out[:, 0] += a * y * np.cos(pan * np.pi / 2); out[:, 1] += a * y * np.sin(pan * np.pi / 2)
    tine = 0.035 * np.sin(2 * np.pi * f * 4.0 * t) * np.exp(-t / 0.09)        # μικρό «γυάλινο» ding
    out += tine[:, None]
    return out * (env(n, .008, tau) * amp)[:, None]

def bell(f, dur, tau, amp=1.0):
    """Εκλεπτυσμένη καμπάνα: λιγότερες υψηλές αρμονικές από πριν."""
    n = int(dur * SR); t = np.arange(n) / SR
    y = np.zeros(n)
    for m, a, k in [(1, 1, 1), (2, .18, .6), (3, .05, .4), (4.07, .02, .25)]:
        y += a * np.sin(2 * np.pi * f * m * t) * np.exp(-t / (tau * k))
    y *= env(n, .006, 1e9)
    return np.stack([y, y], 1) * amp

def comb(x, d, g):
    y = x.copy()
    for k in range(d, len(x), d): y[k:k + d] += g * y[k - d:k][: len(y[k:k + d])]
    return y
def allpass(x, d, g):
    y = np.zeros_like(x); buf = np.concatenate([np.zeros(d), x])
    for k in range(0, len(x), d):
        e = min(k + d, len(x)); prev = y[k - d:e - d] if k >= d else np.zeros(e - k)
        y[k:e] = -g * x[k:e] + buf[k:e] + g * prev
    return y
def reverb(st, rt=2.4, wet=.24):
    out = np.zeros_like(st)
    for ch, off in [(0, 0), (1, 23)]:
        x = np.concatenate([np.zeros(int(.022 * SR)), st[:, ch]])[: len(st)]       # pre-delay
        acc = np.zeros(len(st))
        for ms in [29.7, 37.1, 41.1, 43.7]:
            d = int(ms / 1000 * SR) + off; acc += comb(x, d, 10 ** (-3 * d / SR / rt))
        for ms, g in [(5.0, .7), (1.7, .7)]: acc = allpass(acc, int(ms / 1000 * SR) + off // 4, g)
        out[:, ch] = acc / 4
    return st + wet * out

def render(notes, voice, total):
    mix = np.zeros((int(total * SR), 2))
    for f, at, dur, tau, amp in notes:
        s = voice(f, dur, tau, amp); i = int(at * SR); mix[i:i + len(s)] += s[: len(mix) - i]
    mix = reverb(mix)
    fade = int(.6 * SR); mix[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 2
    return mix / np.abs(mix).max() * 0.89

def save(path, mix):
    pcm = (np.clip(mix, -1, 1) * 32767).astype('<i2')
    with wave.open(path, 'wb') as w: w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())


# ── Σύντομοι ήχοι διακόπτη θέματος (ίδια χροιά με το καμπανάκι εισόδου) ──
def render_short(notes, total, rt=0.9, wet=0.16):
    mix = np.zeros((int(total * SR), 2))
    for f, at, dur, tau, amp in notes:
        s = rhodes(f, dur, tau, amp); i = int(at * SR); mix[i:i + len(s)] += s[: len(mix) - i]
    mix = reverb(mix, rt=rt, wet=wet)
    fade = int(.16 * SR); mix[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 2
    return mix / np.abs(mix).max() * 0.85

A4, C5 = 440.0, 523.25
# προς σκούρο: κατεβαίνει (Ντο → Λα) · προς φωτεινό: ανεβαίνει (Λα → Ντο)
save(sys.argv[1] + '/switch-dark.wav',  render_short([(C5, 0.00, .50, .16, .85), (A4, 0.075, .48, .20, 1.0)], 0.58))
save(sys.argv[1] + '/switch-light.wav', render_short([(A4, 0.00, .50, .16, .85), (C5, 0.075, .48, .20, 1.0)], 0.58))
print("ok")
