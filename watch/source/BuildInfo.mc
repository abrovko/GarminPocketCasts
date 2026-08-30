import Toybox.Lang;

// The build stamp, so a running watch can be matched against a known build.
//
// Rewritten by tools\Deploy-Watch.ps1 immediately before every release build,
// which is what makes it trustworthy: there is no constant to remember to
// bump, and the value compiled into the .prg is always the moment it was
// built. A plain `monkeyc` invocation does not rewrite it, so a hand-built
// binary keeps whatever was here - that is why the placeholder reads "dev"
// rather than a number that would look authoritative and be wrong.
//
// Surfaced in two places: printed by GarminPocketCastsApp.onStart() on every
// app invocation, and shown as the last row of the playback hub. Deploying
// prints the same value, so the two can be compared without pulling logs.
module BuildInfo {
    const STAMP = "260830-105004";
}
