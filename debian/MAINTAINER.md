## Maintainer Notes

If you are reading this, you probably forgot how to release a new version. Keep
reading.

### Debianizing branches

Converting an existing repository that combines Debian packaging and the upstream development is a bit tricky, since you want to create a new debian/master branch that shares the history of the current master and an upstream/latest branch that can be merged into debian/master and used by gbp import-orig, but you also want to remove the debian/* directory from the master branch. The first time I tried this, I ended up merging the removal of the debian/* directory into my debian/master branch and having to back out of that.

After some experimentation, the following approach seems to work the best:

1. Before removing debian/* from master, create the debian/master branch with git branch debian/master master.

2. git rm -r debian on the master branch and commit it. Do the same for the develop branch.

3. git branch upstream/latest master. Now you have an upstream branch with the right history and without the debian/* directory, although it doesn't match the upstream tarball release (it's missing generated files).

4. Record in Git that the debian/master branch is already a correct reflection of the changes relative to the upstream/latest branch by adding a merge commit. git checkout debian/master and then git merge -s ours upstream/latest. The -s ours is the key trick; it records the merge commit without deleting debian/* as part of the merge.

5. Now you can run gbp import-orig on the current upstream release tarball, let it fix up the upstream branch to match the release tarball by adding all the generated files, and then merge them into the debian/master branch. You can do this now if you haven't made any changes since the previous release. If you have made changes, the easiest thing to do is to wait until you do another release and then have that be the first true imported release.


### If you are the maintainer of this package

#### Making snapshot versions

  git fetch upstream
  git merge v1.1
  gbp dch --debian-branch=debian/sid --snapshot --auto debian/
  gbp buildpackage --git-ignore-new --git-pristine-tar --git-pristine-tar-commit --git-upstream-tag='v%(version)s'

#### Making release versions


### If you are a collaborator for this package

    gbp import-dsc --git-debian-branch=debian/master \
        --git-upstream-branch=upstream/latest /path/to/dsc

    gbp import-orig --git-debian-branch=debian/master \
        --git-upstream-branch=upstream/latest /path/to/upstream/tarball
