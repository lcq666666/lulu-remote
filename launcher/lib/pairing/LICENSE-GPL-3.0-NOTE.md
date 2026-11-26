# Licence for lib/pairing/ — GPL-3.0

This directory is licensed under the **GNU General Public License v3.0
(GPL-3.0)**. Every file in it carries an `SPDX-License-Identifier:
GPL-3.0-only` header.

Full licence text: https://www.gnu.org/licenses/gpl-3.0.txt

Before any distribution (public repo, release ZIP, installer), copy the
full GPL-3.0 text into this directory as `COPYING` and add a copyright
notice with the author name(s). This scaffold ships only this note, not
the full text, because the full text is a standard document to be added
verbatim at release time — do not paraphrase it.

Why GPL-3.0 here: the pairing module re-implements the GameStream
pairing handshake from moonlight-common-c / moonlight-chrome logic
(GPL-3.0 projects). Keeping it in its own GPL-3.0 module, separate from
the MIT launcher code, keeps the licence boundary clean: the launcher
only calls this module, and the module only talks to Sunshine over
HTTP/TLS — it does not link any GPL library into the launcher.
