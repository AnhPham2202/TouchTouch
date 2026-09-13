# TouchTouch 👆👆

I used Windows for years before switching to a Mac, and `Cmd + C / Cmd + V` never felt quite right. My fingers kept doing this awkward little crossover every time I copied something.

So I made **TouchTouch**.

A tiny, free alternative to installing BetterTouchTool when all you want is a nicer way to **Copy & Paste**.

## Gestures

TouchTouch supports:

* `Cmd + 1-finger tap`
* `Cmd + 2-finger tap`
* `3-finger double tap`
* `4-finger double tap`
* `3-finger hold`

Pick what feels comfortable for Copy and Paste. That's it.

No giant settings panel, no automation engine, no 147 actions you'll never use.

## Install

Download the latest `.dmg` from **Releases** and drag TouchTouch into Applications.

TouchTouch is currently unsigned, so macOS may block it on first launch. If that happens:

**System Settings → Privacy & Security → Open Anyway**

Then allow TouchTouch under:

**Privacy & Security → Accessibility**

## Why the security warning?

TouchTouch is free and open source. Apple wants $99/year to make this warning disappear, and unfortunately, I'm broke as fuck.

The source is right here if you'd rather inspect it and build it yourself.

## Under the hood

macOS doesn't expose a public API for global raw trackpad touches, so TouchTouch uses Apple's private `MultitouchSupport` framework.

It recognizes the configured tap and hold gestures from those touch frames, then uses Accessibility permission to send normal `Cmd + C` or `Cmd + V` keyboard events.

Because `MultitouchSupport` is private, a future macOS update could break it. Such is life.

## License

MIT
