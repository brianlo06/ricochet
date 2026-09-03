# Ricochet

A top-down tank battle for a Mac plugged into a TV. Your phone is the gamepad: hold it
sideways, steer with the pad under your left thumb, fire with the button under your right.
Up to four players, each with their own phone and their own tank. Shells bounce.

Built on [AirPoint](https://github.com/brianlo06/airpoint), which supplies the whole
phone-to-Mac stack — TLS, pairing, the WebSocket protocol — and now a `pad_state` event,
which is what this game needed from it and did not exist until this game was built. The
shape of the project is [Reticle](https://github.com/brianlo06/reticle)'s: a rules module
with no window and no network, a hundred-and-fifty-line handler, a SpriteKit scene.

**Needs no permissions at all**, on either end. The Mac draws its own tanks rather than
moving the system cursor, and the phone is a pad rather than a gun, so there is no motion
sensor to ask for.

---

## Play

```bash
git clone https://github.com/brianlo06/ricochet.git && cd ricochet
swift build
./.build/debug/ricochet
```

**The QR code is on the game screen**, in the lobby, alongside the address and the
six-digit code. On each player's phone:

1. Scan the QR code on the TV, or open `https://<your-mac-ip>:8445`.
2. Safari warns that the certificate is untrusted. Expected — the game signs its own,
   because it runs on your machine rather than a public server. *Show Details* →
   *visit this website*.
3. Approve the player in the terminal.
4. **Turn the phone sideways**, like watching a video. The page turns itself whether or
   not rotation lock is on. Drive with the pad under your left thumb, tap **FIRE** under
   your right.

Alone? Press **Bots** on the phone (or **B** on the Mac) until you have company.

```
--port <n>          TLS port (default 8445, one above Reticle so all three can run at once)
--players <n>       Seats, 1–8 (default 4). Bots take the seats people leave
--bots <n>          Bots to start with (default 0)
--map <name>        One map every round instead of a random one
--fullscreen        Start filling the screen. F toggles it.
--mute              Start silent. M toggles it.
--auto-approve      Skip the approval prompt. Testing only.
```

## Controls

| | |
|---|---|
| **Pad up / down** | Drive forward / reverse, the way the tank faces. Reverse is slower. |
| **Pad left / right** | Turn. The diagonals do both at once — slide your thumb, do not lift it. |
| **A** | Fire. Three shells in the air at a time, then you wait for one to land. |
| **A** in the lobby | Ready up. **A** on the results screen asks for another round. |
| **Mode** | Cycle the rules. Refused mid-round. |
| **Bots** | One more bot, wrapping round to none. Refused mid-round. |
| **Map** | Another map for the next round. Refused mid-round. |

You can drive around in the lobby while the others join. Everything on the map works in
the lobby too — the sweeper sweeps, the pits are pits — but nothing counts.

## Bots

Bots take the seats people leave and give them back when somebody joins. With the default
four seats, one person can have up to three bots, two people up to two, and so on; a person
arriving at a full table takes the newest bot's seat rather than being refused. Bots are
always ready, so they never hold up the lobby, and they leave when the last person does.

A bot picks the nearest tank it can see and shoots it, leading the shot a little. If it
cannot see anyone it plans a route on a coarse grid and drives it, which is how it finds
its way through the maze. Anything coming its way, it steps out of — sideways if it can,
backwards if it must. It is not clever, and it is deliberately not a laser: every shot has
a little error in it that changes each time. What makes it feel like an opponent rather
than a turret is that it dodges and that it comes and finds you.

Every bot decision comes from the game's seeded generator, so a round with bots replays
exactly from its seed and its button log, like a round without.

## Maps

A different one each round, never the same one twice running. Ten of them:

| | |
|---|---|
| **Crossfire** | A pillar, four bars, two stubs. The original. |
| **Labyrinth** | A maze, different every time, with a fifth of its walls knocked through so there are loops. A perfect maze is a corridor chase; the loops make it a battle. |
| **Pinball** | Round bumpers. A shell coming off one keeps its bounces. |
| **Crumble** | A cross and a ring of bricks. A shell that hits one takes it, and the shell, with it. Bricks come back next round. |
| **Currents** | Conveyor strips that carry tanks along. Shells fly over them. |
| **Portals** | Two pairs. What goes in one comes out the other, still going the way it was — and that includes your own shell coming back. |
| **Shutters** | Gates that open and close on different clocks. A gate will not close on a tank standing in it. They flicker before they change. |
| **Fortress** | A keep in the middle with a door in each wall. |
| **Sweeper** | Two bars that travel back and forth. A tank between one and something solid is crushed. |
| **Chasm** | A gap down the middle with two bridges. Shells cross it; tanks that drive in are gone. |

Maps are laid out in fractions of one fixed arena and checked by the same tests: nothing off
the edge, every spawn clear, and every spawn reachable from every other with a tank's
radius — which for the maze means the generator cannot strand a seat behind a wall.

## Modes

| | |
|---|---|
| **Skirmish** | 90 seconds, respawns, most kills wins |
| **Last Tank Standing** | Three lives, no respawn after the last, ends when one tank is left |
| **Ricochet** | Shells bounce three times and live longer. Two in the air at once, because the field would fill. |

A mode is a named set of `Game.Settings` rather than a branch in the rules, so every mode is
covered by the same tests and adding one is a matter of choosing numbers.

## How a round works

**Lobby** → everyone presses A. **Countdown** → 3, 2, 1. **Round** → 90 seconds.
**Results** → kills, deaths, accuracy for 12 seconds, then back to the lobby.

- Shells come off the border and the blocks once (three times in Ricochet), then the next
  wall absorbs them. **Your own shell can come back and get you.** That is an own goal: a
  death for you and a kill for nobody.
- A destroyed tank comes back after 2.5 seconds at the spawn **farthest from everybody
  else**, blinking and untouchable for a moment. Firing drops the shield at once, so it is
  for arriving, not for fighting from behind.
- Firing faster than the reload is ignored rather than counted. A shot that never happened
  is not a mistake.
- A tank driven into a wall at an angle slides along it. The difference between steering
  round a bar and being glued to one.
- Ties on the leaderboard break toward fewer deaths, then toward seat.
- **Your colour comes from your seat, not your rank.** Seat decides your starting corner
  too, and it is held for as long as you are connected.

The arena is one fixed layout at one fixed size, scaled to whatever screen this is: a
pillar in the middle, a bar in each quadrant, a stub at each side. Symmetric, so no seat
has a shorter route to anybody, and the bars sit exactly where a shot from one corner at
the opposite corner would go.

## What comes from AirPoint

| | |
|---|---|
| `RemoteKit` | Wire protocol, validation, rate limiting, pairing crypto — and `pad_state` |
| `RemoteServer` | TLS with SAN management, HTTP + WebSocket on one port, pairing, sessions |

What this repository adds:

- **`Sources/RicochetCore/`** — the rules, the maps and the bots. No SpriteKit, no network,
  no clock, and one seeded generator: a whole round replays from its seed and a log of
  button states, bots and mazes included.
- **`Sources/Ricochet/GameHost.swift`** — a `RemoteSessionHandler`. Turns a pad state
  into a throttle and a steering direction, a tap into a shell.
- **`Sources/Ricochet/GameScene.swift`** — SpriteKit rendering. The arena lives in one
  scaled node; the HUD is laid out over it in screen space.
- **`Sources/Ricochet/Resources/web/`** — a controller with a round d-pad and a trigger.

### The pad event

AirPoint had taps and it had motion; it had no way to say "this button is still down". A
gamepad is nothing but that. So this game added one event to the protocol, and its shape
was the interesting decision:

**`pad_state` carries every button currently held, not a press or a release.** A lost
`key_press` costs a keystroke. A lost release leaves a tank driving into a wall until the
player notices — the worst failure a gamepad has. Sending the whole set means each frame
supersedes the last and a dropped one is corrected by the next. The controller repeats a
held state four times a second, and the rules treat a state older than a second as
released, so a phone that locks mid-press is a tank that stops rather than one that keeps
going. Both halves are tested: the timeout in `GameTests`, the wire shape in AirPoint.

A misspelt button is refused with an explanation rather than decoded as "nothing held".
That was a bug in the first draft, caught by its own test, and it is the kind that would
have looked like a flaky d-pad on a phone.

## Feedback

The phone is a pad that kicks; the television is the room. Both render the same cue
vocabulary the host raises, so there is one place that decides what anything means:

| | |
|---|---|
| Fire | A light tick. It happens constantly, so it stays well under everything else. |
| Destroying someone | A bang and a rising note, with **+1** on your phone |
| Being destroyed | A long low buzz, with **who got you** on your phone |
| An own goal | The same, and it says so |
| A ricochet | **Nothing.** Four players' shells bouncing is a patter, and a phone that buzzed for each would never stop. |
| Countdown, round start and end | As in Reticle: one beat per second, a fanfare, a long buzz |

Tones are synthesised at both ends — in the browser on the phone, at launch on the Mac —
so there are no audio assets to ship. The synthesis is Reticle's, unchanged, because the
vocabulary is the same.

## Development

```bash
./tools/dev.sh    # build, test, launch the game, join it with three simulated gamepads
swift test        # rules only, no window server or phone needed
```

`tools/smoke.mjs` joins a running game over the real protocol with several players at
once: pairing, seats, readying, adding a bot, driving and firing through AirPoint's
validation and rate limiting, cues routed back to the right phones, and a misspelt button
being refused without costing the session.

## License

MIT.
