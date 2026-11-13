#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
required_files=(
  "README.md"
  "CONTRIBUTING.md"
  "SECURITY.md"
  "LICENSE"
  "THIRD_PARTY_NOTICES.md"
  "docs/ARCHITECTURE.md"
  "docs/RELIABILITY.md"
  "docs/SECURITY.md"
  "package.json"
  "plugins/ultraterm-computer-use/.codex-plugin/plugin.json"
  "plugins/ultraterm-computer-use/.mcp.json"
  "plugins/ultraterm-computer-use/assets/ultraterm-computer-use.svg"
  "plugins/ultraterm-computer-use/assets/ultraterm-computer-use-small.svg"
)

failed=0
for path in "${required_files[@]}"; do
  if [[ ! -f "${repo_root}/${path}" ]]; then
    echo "Missing required public file: ${path}"
    failed=1
  fi
done

if [[ -d "${repo_root}/.github/workflows" ]]; then
  echo "GitHub Actions workflows are not part of this repository"
  failed=1
fi

if grep -R -n -E '/Users/|/home/|/private/tmp/|~/.codex|YOUR_TEAM_ID|analytics\.example' \
  "${repo_root}/README.md" "${repo_root}/CONTRIBUTING.md" "${repo_root}/SECURITY.md" "${repo_root}/docs" \
  >/dev/null 2>&1; then
  echo "Public documentation contains a machine-specific path or private release detail"
  failed=1
fi

doc_files=()
for f in README.md CONTRIBUTING.md SECURITY.md CHANGELOG.md; do
  [[ -f "${repo_root}/${f}" ]] && doc_files+=("${f}")
done
while IFS= read -r f; do
  doc_files+=("${f#"${repo_root}/"}")
done < <(find "${repo_root}/docs" "${repo_root}/skills" -type f -name '*.md' 2>/dev/null | sort)

# (a) CJK characters and (b) dead relative links or repo paths and (c) GitHub Actions mentions.
for f in ${doc_files[@]+"${doc_files[@]}"}; do
  if ! cjk_hits="$(perl -CSD -ne 'print "$ARGV:$.: contains CJK characters\n" if /[\x{2E80}-\x{9FFF}\x{AC00}-\x{D7AF}\x{F900}-\x{FAFF}\x{FF00}-\x{FFEF}\x{3000}-\x{303F}]/; close ARGV if eof' "${repo_root}/${f}")"; then
    echo "check-docs: could not scan ${f} for CJK characters"
    failed=1
  fi
  if [[ -n "${cjk_hits}" ]]; then
    echo "${cjk_hits//${repo_root}\//}"
    failed=1
  fi

  link_hits="$(perl -CSD -e '
    use File::Basename; use Cwd qw(abs_path);
    my ($root, $rel) = @ARGV; my $file = "$root/$rel"; my $dir = dirname($file);
    open(my $fh, "<:encoding(UTF-8)", $file) or die "cannot open $file";
    my $in_fence = 0;
    while (my $line = <$fh>) {
      if ($line =~ /^\s*(```|~~~)/) { $in_fence = !$in_fence; next; }
      my @cands;
      while ($line =~ /\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g) {
        my $t = $1;
        next if $t =~ m{^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#|/)};
        $t =~ s/[#?].*$//; next if $t eq "";
        push @cands, ["$dir/$t", $t];
      }
      while ($line =~ /`((?:docs|scripts|apps|packages|skills|plugins|test)\/[^`\s]*)`/g) {
        push @cands, ["$root/$1", $1];
      }
      for my $c (@cands) {
        my ($full, $shown) = @$c;
        next if $shown =~ /[*?<>{}\[\]]|\$/;
        next if $shown =~ m{(?:^|/)(?:dist|\.build)(?:/|$)};
        $full =~ s{/+$}{};
        print "$rel:$.: missing path $shown\n" unless -e $full;
      }
    }' "${repo_root}" "${f}")" || { echo "check-docs: could not scan ${f} for links"; failed=1; }
  if [[ -n "${link_hits}" ]]; then
    echo "${link_hits}"
    failed=1
  fi

  actions_hits="$(perl -CSD -ne 'print "$ARGV:$.: mentions GitHub Actions, which this repository does not use\n" if /GitHub Actions|\.github\/workflows|actions\/checkout/i; close ARGV if eof' "${repo_root}/${f}")"
  if [[ -n "${actions_hits}" ]]; then
    echo "${actions_hits//${repo_root}\//}"
    failed=1
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  exit 1
fi

echo "Public documentation checks passed"
