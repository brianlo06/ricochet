# Ricochet — design notes

## Why the protocol grew an event

Reticle made a point of adding nothing to AirPoint's protocol: a tap was `left_click`, and
the stock controller could play the game. That worked because a gun has one button and it
is either pressed or it is not, and a press is an event.

A gamepad is the other thing. "Forward" is not an event, it is a condition that holds for as
long as a thumb is down, and AirPoint had no way to say it. `key_press` is a tap. `drag_start`
and `drag_end` are a pair, but they are rate-limited at ten a second and they describe a
mouse button. So this is the first host to change the protocol, and the choice of *what* to
add is the design decision this project is about.

## Why the whole state, and not press and release

The obvious event is `button {name, down: true|false}`. It was rejected for one reason: a
release is the one message that must not be lost. Drop a press and the player presses again.
Drop a release and their tank drives into a wall until they work out why, which on a
television across a room takes several seconds and looks exactly like the game being broken.

`pad_state` carries every button currently held. Each frame supersedes the last, so a dropped
one is corrected by the next. It costs a few bytes per message and nothing else, and it makes
two more things straightforward:

- The controller repeats a held state four times a second, and the rules treat a state older
  than a second as released. A phone that locks, backgrounds or dies mid-press is a tank
  that stops. This is tested in `GameTests` with a clock: hold forward, go quiet, and the
  tank coasts for exactly the timeout and no further.
- A reconnect mid-press just sends the current state to the new session.

The rate limit is sixty a second — generous for a thumb, and well under the motion budget.

## Why an unknown button is an error

The first draft decoded `pad_state` through the same lenient path as `left_click`, where a
missing or malformed payload falls back to a default. For a click the default is "one click",
which is right. For a pad the default is "nothing held", which turned `["up", "fire"]` into
an empty hand — silently, because that is what lenient means. A test written to check that
`fire` was refused failed, and the fix was to decode strictly whenever a payload is present
and fall back only when there is none. An absent payload genuinely means an empty hand, and
that is worth being able to say in three bytes.

## Why the arena is a fixed size

Reticle resizes its arena with the window and re-clamps every reticle. A tank halfway
through a gap cannot be re-clamped; scaling the layout under it would put it inside a wall.
So the rules run in one logical space, 1600 by 900, and the scene scales a single node to
fit. It also means a replay is a replay: the same button log on a different television is the
same round.

## Where the randomness is

The first version had none: where a tank comes back is decided by where everyone else is —
the spawn farthest from any living tank, ties going to the one farthest from where you died,
which is where the gun that got you probably still is. Maps and bots needed some, and it went
in as one seeded generator on the game rather than as calls to the system one, so a round is
still a pure function of its seed, its button log and its clock. The bot test that replays
five seconds twice and compares every position is what holds that.

## Why a map is a builder and not a file

Ten maps are ten functions from a generator to an arena. Most ignore the generator; the maze
does not, and the shape of "a map" had to allow for that from the start or the maze would
have been a special case. It also meant every map got the same three tests for free, and
the one that matters — every spawn can reach every other with a tank's radius — is the one
a hand-made layout would have got wrong eventually.

## Why the maze has loops

A recursive-backtracker maze is perfect: exactly one route between any two cells. In a tank
game that is a corridor with someone at the end of it, and the only decision is who fires
first. A fifth of the remaining walls are knocked through afterwards, which turns dead ends
from a rule into a risk.

## Why a gate will not close on a tank

A closed gate is a wall, and a wall that appears around a tank pins it there until the gate
opens again — long enough to be shot at leisure by whoever noticed. So the rules treat a
closed gate with a tank in it as open. It reads as a door with a safety edge, which is what
it is; the sweeper, by contrast, is a press, and crushing is what it is for.

## Why bots take the seats people leave

The seat limit is the palette's: eight colours a television can keep apart, four by default.
Bots fill whatever people are not using and give a seat back the moment somebody joins, so
"up to three bots alone, up to two as a pair" falls out of one rule rather than a table of
them. They also leave when the last person does. Bots play with people, not instead of them.

## What the bot knows

Nothing a person does not. It reads the same `players`, `shells` and `arena` the renderer
draws, and it drives through `setControls` and `fire` like a phone. The one thing it has
that a person lacks is a route planner — a forty-point grid and A* — and that is because
the maze is a map and a bot that could not find its way through it would sit in a corner.
The line-of-sight test it shoots on is the arena's own, so a bot cannot shoot through a
wall a person cannot.

## Why the shield drops when you fire

A tank that has just appeared blinks and cannot be hit for a moment, or a respawn is a free
kill for whoever happens to be facing that corner. But a shield you can shoot from is a
tactic, and a bad one: park in the corner, come back untouchable, fire. Firing ends the
shield at once. It is for arriving.

## Why a ricochet is silent

Every other event of consequence reaches the phone as a cue. Bounces do not. With four
players and up to three shells each, a round is a constant patter of ricochets, and a phone
that buzzed on each would never stop buzzing — and would drown the one buzz that matters,
which is the long low one that means you have been hit. The television draws a spark; the
phone says nothing.

## Why tanks can drive in the lobby

The lobby is where people find out which phone is which tank and which way the pad goes.
Letting the tanks move while the others are still scanning the code costs nothing and
replaces a paragraph of instructions. Shells are the only thing that exists solely in a round.

## What building this found in the library

Reticle found two bugs in AirPoint. This game found a gap rather than a bug — the missing
held-button event — and one thing about the lenient payload path that was correct for every
existing event and wrong for the new one. Neither would have been found by planning the
protocol harder; both fell out of building a third host on it.

## Why the guns are one engine

Eleven guns could have been eleven kinds of projectile. They are one `Shell` with a
`Weapon` on it and a profile the engine reads: how many, how fast, how many bounces, and a
handful of behaviours — homing, splash, mines, ghosts. A new gun is a profile, and every
gun inherits every fix to the physics. It also means the maps' features work on all of
them without anyone having thought about the combination: a seeker through a portal, a
mortar off a bumper, mines on a conveyor.

## Why points are never spent

"Save up for a weapon" could mean buying. It means reaching: every gun is a threshold on
lifetime kills, and a gun reached is a gun kept. Spending would mean a player who tried the
Railgun and disliked it is poorer for it, and a scoreboard that goes down is a scoreboard
people stop caring about. The progress file has the same rule: a write can only raise a
score, so a stale reconnect cannot take a kill away.

## Why the cost ordering is tested

Ten guns with different niches cannot be ordered by feel alone, and the claim that a
twenty-point gun is better than a five-point one has to mean something checkable. The
measure chosen is the one that is fair to all of them: a stationary target in the open at
a middling distance, trigger held, time to first kill. No direct-fire gun may be slower
than the cannon. The guns whose point is not a straight shot — scatter, mines, the nova —
are checked for the thing they are for instead.

## Why identity comes from AirPoint

Persistence needs to know it is the same phone. The connection id is new every time; the
device name is "iPhone" for everybody. The phone already generates an identity once and
keeps it in local storage for pairing, and AirPoint 0.4.1 hands it to the host. That is
the key, and nothing is written to the phone that was not there already.
