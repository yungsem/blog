#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_DEPLOY_REPO="git@github.com:yungsem/yungsem.github.io.git"
DEPLOY_REPO="${DEPLOY_REPO:-$DEFAULT_DEPLOY_REPO}"
SOURCE_REPO="${SOURCE_REPO:-git@github.com:yungsem/blog.git}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
PUBLISH_DIR="${PUBLISH_DIR:-public}"
DEFAULT_COMMIT_MESSAGE="${1:-Deploy blog $(date '+%Y-%m-%d %H:%M:%S %z')}"
SOURCE_COMMIT_MESSAGE="${SOURCE_COMMIT_MESSAGE:-$DEFAULT_COMMIT_MESSAGE}"
DEPLOY_COMMIT_MESSAGE="${DEPLOY_COMMIT_MESSAGE:-$DEFAULT_COMMIT_MESSAGE}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_cmd git
require_cmd hugo
require_cmd rsync

cd "$ROOT_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "$ROOT_DIR is not a Git repository"
fi

git config --local deploy.pagesRepo "$DEPLOY_REPO"

echo "Checking deploy target: $DEPLOY_REPO"
if ! remote_check="$(git ls-remote "$DEPLOY_REPO" 2>&1)"; then
  die "Cannot access deploy repository: $DEPLOY_REPO
$remote_check
Check that the repository exists and that the configured SSH key has access."
fi

target_branch_exists=0
if git ls-remote --exit-code "$DEPLOY_REPO" "refs/heads/$DEPLOY_BRANCH" >/dev/null 2>&1; then
  target_branch_exists=1
fi

tmp_dir=""
deploy_succeeded=0
cleanup() {
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    rm -rf -- "$tmp_dir"
  fi

  if [[ "$deploy_succeeded" == "1" && -e "$PUBLISH_DIR" ]]; then
    rm -rf -- "$PUBLISH_DIR"
    echo "Removed temporary publish directory: $PUBLISH_DIR"
  fi
}
trap cleanup EXIT

if [[ -e "$PUBLISH_DIR" ]]; then
  echo "Removing previous temporary publish directory: $PUBLISH_DIR"
  rm -rf -- "$PUBLISH_DIR"
fi

git clone "$DEPLOY_REPO" "$PUBLISH_DIR"

if [[ "$target_branch_exists" == "1" ]]; then
  git -C "$PUBLISH_DIR" fetch origin "$DEPLOY_BRANCH"
  git -C "$PUBLISH_DIR" checkout -B "$DEPLOY_BRANCH" "origin/$DEPLOY_BRANCH"
else
  # A newly recreated repository may be empty or may only have another
  # default branch. Keep its existing commit, then publish from main.
  git -C "$PUBLISH_DIR" checkout -B "$DEPLOY_BRANCH"
fi

origin_url="$(git -C "$PUBLISH_DIR" remote get-url origin)"
echo "Deploy target: $origin_url ($DEPLOY_BRANCH)"

if [[ "$target_branch_exists" != "1" ]]; then
  echo "No existing $DEPLOY_BRANCH branch on deploy target; creating it."
fi

tmp_dir="$(mktemp -d)"

echo "Building Hugo site..."
hugo --destination "$tmp_dir"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo "Committing blog source..."
  git add -A
  git commit -m "$SOURCE_COMMIT_MESSAGE"
else
  echo "No blog source changes to commit."
fi

source_upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
source_branch="$(git branch --show-current)"
if [[ -n "$source_branch" ]]; then
  echo "Pushing blog source to $SOURCE_REPO ($source_branch)..."
  git push "$SOURCE_REPO" "HEAD:$source_branch"
else
  echo "No upstream configured for blog source; skipping source push."
fi

# Keep GitHub Pages marker/domain files unless Hugo generated replacements.
for file in CNAME .nojekyll; do
  if [[ -f "$PUBLISH_DIR/$file" ]] && [[ ! -e "$tmp_dir/$file" ]]; then
    cp -p "$PUBLISH_DIR/$file" "$tmp_dir/$file"
  fi
done

rsync -a --delete --exclude ".git/" "$tmp_dir"/ "$PUBLISH_DIR"/

if [[ -z "$(git -C "$PUBLISH_DIR" status --porcelain)" ]]; then
  echo "No changes to deploy."
  deploy_succeeded=1
  exit 0
fi

git -C "$PUBLISH_DIR" add -A
git -C "$PUBLISH_DIR" commit -m "$DEPLOY_COMMIT_MESSAGE"
git -C "$PUBLISH_DIR" push origin "$DEPLOY_BRANCH"

deploy_succeeded=1
echo "Deploy complete."
