# Notes for coding agents

[CONTRIBUTING.md](CONTRIBUTING.md) holds the project's conventions: follow it in full. These notes
add how the maintainer works with an agent.

- **Starting an issue.** Begin with `gh issue view N --comments`, and read the comments on related
  closed issues too.
- **Trying a change.** When the maintainer tries a change, build and launch the app right away:
  `make run`. Build into a folder of its own (`zig build --prefix <folder>`) when the maintainer is
  running a copy, and never stop their copy. Once they are happy with it, run the checks and
  commit.
- **Checking a screen.** `negscan open ... --screenshot <file.png>` draws without a window and
  saves the frame, for checking a screen against the design without showing a window on the
  maintainer's screen. Use a copy of their library, so nothing they're using changes.
- **Scanners.** Don't scan or move a scanner unless the maintainer asks; a scan on their hardware
  is their call.
- **Pull requests.** Push the feature branch and open the pull request when the change is ready.
  The maintainer merges it. See one pull request merged before starting the next feature.
- **Attribution.** Commits and pull requests carry the maintainer's git identity alone. End commit
  messages and pull request bodies with their content, leaving out trailers such as
  `Co-Authored-By` and "Generated with" footers.
- **Gaps.** File an issue for each gap you leave, and name the issues in your reply.
- **Plain English.** Write docs, comments, messages, issues, pull requests and replies in plain,
  simple technical English, the way you would explain the code to a colleague: normal word order,
  common words, short sentences.
- **Replies.** Use the docs' punctuation in replies too: no em or en dashes.
