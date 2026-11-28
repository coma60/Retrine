# Queue history

The Music app style queue page (`Redesigned/Player/PlayerQueue.m`) keeps History through picks made on it (issue #82,
item 4). Spotify keeps no History the page can show for them: a song of History is played again by rewinding Spotify's
History to it (the songs after it go back to come), and a song picked out of another context (autoplay's) starts a
History of its own. The page carries on what it showed, with the song that was playing, ahead of what Spotify records
once the song picked plays, and lets go once Spotify has recorded ten songs of its own. With nothing picked on the page,
History is Spotify's as before (`harness/player/queue-check.sh` keeps those checks).

```sh
harness/queue-history/check.sh
```

It compiles the production `PlayerQueue.m` into a Mac Catalyst app with Spotify as the only double and checks:

- a pick further down Continue Playing: the song that was playing joins History, the songs skipped stay out, and their
  rows move up with the rows after them and fade, cut off where the songs to come begin;
- a pick out of autoplay, where Spotify begins another History (with new uids): earlier History stays;
- a song of History played again: every song played stays, the song played again leaves its place; the song playing is
  never listed. A row in Spotify's History is gone back to, a row only the page keeps is skipped ahead to when it is to
  come, and plays nothing (read as text) when Spotify has it in neither;
- a pick while History is carried keeps it in place until the song picked plays;
- Spotify going back from outside past what the carry stood on lets the carry go (History is Spotify's again), as do ten
  songs Spotify records of its own;
- Clear (also between a pick and Spotify moving, keeping the song that was playing), a skipped song played later, a
  pick Spotify does not follow, and a shorter History reported for the same song;
- a report that reloads the rows mid-slide starts them where they stand on screen (a real 0.45 s spring), not from a
  straight-line estimate that drew them back down, and a reload that is not placed leaves no distance behind;
- a pick with History pulled down glides back to rest at the tap and shows the change from there.

Not checked here: the phone. Spotify's real History lengths and uids around autoplay were read from a screen recording,
not from the device.
