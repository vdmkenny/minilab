# Notes for coding agents

[CONTRIBUTING.md](CONTRIBUTING.md) has the project's conventions: follow all of it. These notes add
how the maintainer likes to work with an agent.

- **Starting on an issue.** Begin with `gh issue view N --comments`, and read the comments on
  related closed issues too.
- **Trying a change.** When the maintainer wants to try a change, build and launch the app straight
  away with `make run`. If they already have a copy running, build into a separate folder
  (`zig build --prefix <folder>`), and never stop their copy. Once they're happy with the change,
  run the checks and commit.
- **Checking a screen.** `minilab open ... --screenshot <file.png>` draws the screen to a file
  without opening a window, so you can compare it with the design without popping windows up on
  the maintainer's screen. Point it at a copy of their library, so nothing they're using changes.
- **Scanners.** Don't scan or move a scanner unless the maintainer asks. Scanning on their hardware
  is their call.
- **Pull requests.** Push the feature branch and open the pull request when the change is ready.
  The maintainer merges it. Wait for one pull request to be merged before starting the next
  feature.
- **Attribution.** Commits and pull requests carry the maintainer's git identity only. Leave out
  trailers like `Co-Authored-By` and "Generated with" footers.
- **Gaps.** File an issue for each gap you leave, and mention the issues in your reply.
- **Plain English.** Write docs, comments, commit messages, issues, pull requests and replies in
  plain, simple technical English, the way you'd explain the code to a colleague. A bit informal
  is fine. Use normal word order, common words and short sentences, and explain things simply.
- **Replies.** Replies follow the docs' punctuation too: no em or en dashes.
