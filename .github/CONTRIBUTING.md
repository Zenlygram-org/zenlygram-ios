# Contributing

This document describes how you can contribute to Zenlygram, an unofficial Telegram client for iOS. Please read it carefully.

**Table of Contents**

* [What contributions are accepted](#what-contributions-are-accepted)
* [Build instructions](#build-instructions)
* [Pull upstream changes into your fork regularly](#pull-upstream-changes-into-your-fork-regularly)
* [How to get your pull request accepted](#how-to-get-your-pull-request-accepted)
  * [Keep your pull requests limited to a single issue](#keep-your-pull-requests-limited-to-a-single-issue)
    * [Squash your commits to a single commit](#squash-your-commits-to-a-single-commit)
  * [Don't mix code changes with whitespace cleanup](#dont-mix-code-changes-with-whitespace-cleanup)
  * [Keep your code simple!](#keep-your-code-simple)
  * [Test your changes!](#test-your-changes)
  * [Write a good commit message](#write-a-good-commit-message)
* [License](#license)

## What contributions are accepted

Bug reports and fixes, performance improvements and documentation fixes are welcome: push to your fork and [submit a pull request][pr]. Before starting a larger change — a new feature, a new user-interface element or a new language — please [open an issue][issues] first and describe what you want to do, so that the work is not lost if it does not fit the app.

We try to review pull requests as fast as possible. If we find issues with your pull request, we may suggest some changes and improvements.

Each commit on the branch `release/appstore` of this repository is exported from the project's development tree. Pull requests and issues are welcome here for review; accepted changes are applied in the development tree and appear with the next release commit, and nothing is merged on the public branch directly.

Most of this code base comes from the upstream projects, [Telegram-iOS][telegram-ios] and [Swiftgram][swiftgram]. Changes to upstream code that are not specific to Zenlygram are best proposed upstream, so that every fork benefits and the change survives the next upstream sync.

## Build instructions

See the [README.md][build_instructions] for details on the various build environments.

## Pull upstream changes into your fork regularly

Zenlygram and its upstreams advance quickly. It is therefore critical that you pull upstream changes into your fork on a regular basis. Nothing is worse than putting days of hard work into a pull request only to have it rejected because it has diverged too far from upstream.

To pull in upstream changes:

    git remote add upstream https://github.com/Zenlygram-org/zenlygram-ios.git
    git fetch upstream

Check the log to be sure that you actually want the changes, before merging (`<default-branch>` is the repository's default branch on GitHub):

    git log upstream/<default-branch>

Then rebase your changes on the latest upstream commits:

    git rebase upstream/<default-branch>

After that, you have to force push your commits:

    git push --force

For more info, see [GitHub Help][help_fork_repo].

## How to get your pull request accepted

We want to improve Zenlygram with your contributions. But we also want to provide a stable experience for our users. Follow these rules and you should succeed without a problem!

### Keep your pull requests limited to a single issue

Pull requests should be as small/atomic as possible. Large, wide-sweeping changes in a pull request will be **rejected**, with comments to isolate the specific code in your pull request. Some examples:

* If you are making spelling corrections in the docs, don't modify other files.
* If you are adding new functions don't '*cleanup*' unrelated functions. That cleanup belongs in another pull request.

#### Squash your commits to a single commit

To keep the history of the project clean, you should make one commit per pull request.
If you already have multiple commits, you can add the commits together (squash them): `git reset --soft HEAD~{N} && git commit` (replace `{N}` with the number of commits you want to squash), write the commit message of the new commit, then `git push --force` to push the new commit to your fork.

For example, if you want to squash the last 5 commits, use `git reset --soft HEAD~5 && git commit`

### Don't mix code changes with whitespace cleanup

If you change two lines of code and correct 200 lines of whitespace issues in a file the diff on that pull request is functionally unreadable and will be **rejected**. Whitespace cleanups need to be in their own pull request.

### Keep your code simple!

Please keep your code as clean and straightforward as possible.
Furthermore, the pixel shortage is over. We want to see:

* `opacity` instead of `o`
* `placeholder` instead of `ph`
* `myFunctionThatDoesThings()` instead of `mftdt()`

### Test your changes!

Before you submit a pull request, please test your changes. Verify that Zenlygram still builds and works and that your changes don't cause other issues or crashes. Where the module you touched has tests (look for a `Tests/` directory next to its sources), run them.

### Write a good commit message

* Explain why you make the changes. [More infos about a good commit message.][commit_message]

* If you fix an issue with your commit, please close the issue by [adding one of the keywords and the issue number][closing-issues-via-commit-messages] to your commit message.

  For example: `Fix #545`

## License

Zenlygram is distributed under the GNU General Public License, version 2 or (at your option) any later version (see [LICENSE](../LICENSE) and [NOTICE.md](../NOTICE.md)). By submitting a pull request you agree that your contribution is licensed under the same terms.

[//]: # (LINKS)
[telegram-ios]: https://github.com/TelegramMessenger/Telegram-iOS
[swiftgram]: https://github.com/Swiftgram/Telegram-iOS
[help_fork_repo]: https://help.github.com/articles/fork-a-repo/
[commit_message]: http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html
[pr]: https://github.com/Zenlygram-org/zenlygram-ios/compare
[issues]: https://github.com/Zenlygram-org/zenlygram-ios/issues
[build_instructions]: ../README.md#quick-compilation-guide
[closing-issues-via-commit-messages]: https://help.github.com/articles/closing-issues-via-commit-messages/
