# Executed inside the sandbox by New-SandboxGitSnapshot. No host commands here.
# Unknown/error states preserve the VM. This checks repository state, not honesty
# of a fully compromised VM or completeness of files outside its private clone.
set -euo pipefail
git rev-parse --is-inside-work-tree >/dev/null
guard_dir=$(mktemp -d /tmp/ocbox-preservation.XXXXXXXX)
trap 'rm -rf -- "$guard_dir"' EXIT

git worktree list --porcelain > "$guard_dir/worktrees"
worktree_count=$(grep -c '^worktree ' "$guard_dir/worktrees" || test "$?" -eq 1)
if [ "$worktree_count" -ne 1 ]; then
    printf '%s\n' OCBOX_MULTIPLE_WORKTREES
    exit 43
fi

# A clean submodule may still contain commits that exist only in this VM.
# Gitlinks do not carry the nested repository objects in the parent bundle.
git ls-files --stage > "$guard_dir/index"
if [ -e .gitmodules ] || grep -q '^160000 ' "$guard_dir/index"; then
    printf '%s\n' OCBOX_SUBMODULE_UNSUPPORTED
    exit 45
fi

# Detect LFS from Git attributes even when git-lfs is not installed. Include
# unstaged/untracked files: they would be added by the snapshot that follows.
git ls-files --cached --others --exclude-standard -z > "$guard_dir/paths"
git check-attr -z --stdin filter < "$guard_dir/paths" > "$guard_dir/attributes"
while IFS= read -r -d '' file; do
    IFS= read -r -d '' attribute
    IFS= read -r -d '' value
    if [ "$value" = lfs ]; then
        printf '%s\n' OCBOX_GIT_LFS_TRACKED
        exit 44
    fi
done < "$guard_dir/attributes"

# Catch pointer files even if the filter declaration has been removed. Check
# both index and working tree (including untracked files added by the snapshot).
for source in --cached --untracked; do
    pointer_code=0
    git grep "$source" -I -l -G '^version https://git-lfs\.github\.com/spec/v1$' -- > "$guard_dir/pointers" || pointer_code=$?
    if [ "$pointer_code" -gt 1 ]; then exit 46; fi
    if [ -s "$guard_dir/pointers" ]; then
        printf '%s\n' OCBOX_GIT_LFS_TRACKED
        exit 44
    fi
done
if command -v git-lfs >/dev/null 2>&1; then
    # Do not hide a failed enumeration behind a grep pipeline.
    if ! git lfs ls-files --all > "$guard_dir/lfs"; then
        printf '%s\n' OCBOX_LFS_INSPECTION_FAILED
        exit 46
    fi
    if [ -s "$guard_dir/lfs" ]; then
        printf '%s\n' OCBOX_GIT_LFS_TRACKED
        exit 44
    fi
fi

git ls-files --others -i --exclude-standard > "$guard_dir/ignored"
if [ -s "$guard_dir/ignored" ]; then
    printf '%s\n' OCBOX_IGNOREDFILES
    exit 42
fi
