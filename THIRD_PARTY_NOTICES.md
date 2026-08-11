# Third-Party Notices

## FFmpeg

FFmpeg Media Extension contains statically linked libraries from FFmpeg 9.0.
FFmpeg is Copyright © the FFmpeg developers and is licensed under the GNU
Lesser General Public License, version 2.1 or later. FFmpeg is a separate
upstream project and is not covered by this repository's MIT license.

The build deliberately disables FFmpeg's GPL, version-3, and nonfree
configuration options. The exact FFmpeg revision is recorded by the `FFmpeg`
Git submodule. Tagged binary releases include a corresponding-source archive
containing the project source, build scripts, and the complete pinned FFmpeg
source used to produce the binaries, so recipients can modify FFmpeg and
rebuild or relink the extensions.

The full LGPL v2.1 text is included as `FFmpeg/COPYING.LGPLv2.1` in the source
tree and as `FFmpeg-LGPL-2.1.txt` inside the application bundle. FFmpeg's
licensing overview is available at <https://ffmpeg.org/legal.html>.

FFmpeg Media Extension is independent and unofficial. It is not an FFmpeg
product and is not affiliated with or endorsed by the FFmpeg project.

## GitHub logo

The GitHub Invertocat mark is used solely to identify links to repositories.
GitHub and the Invertocat mark are trademarks of GitHub, Inc.; the mark is not
covered by this repository's MIT license.
