#!/bin/bash
set -e

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

declare -A aliases
aliases=(
	[$(cat latest)]='latest'
)
declare -A noVersion
noVersion=(
	[oldstable]=1
	[stable]=1
	[testing]=1
	[unstable]=1
	[sid]=1
)

versions=( */ )
versions=( "${versions[@]%/}" )
for version in "${versions[@]}"; do
	arches=( $version/*/ )
	arches=( "${arches[@]%/}" )
	arches=( "${arches[@]#$version/}" )
	eval arches_$version=\( ${arches[@]} \)
done

cat <<-EOH
Maintainers: Tianon Gravi <tianon@debian.org> (@tianon),
             Paul Tagliamonte <paultag@debian.org> (@paultag)
GitRepo: https://github.com/tianon/docker-brew-debian.git
EOH

branches=( master dist )

for branch in "${branches[@]}"; do
	if [ "$branch" = 'master' ]; then
		continue
	fi
	commitRange="master..$branch"
	commitCount="$(git rev-list "$commitRange" --count 2>/dev/null || true)"
	if [ "$commitCount" ] && [ "$commitCount" -gt 0 ]; then
		echo
		echo '# commits:' "($commitRange)"
		git log --format=format:'- %h %s%n%w(0,2,2)%b' "$commitRange" | sed 's/^/#  /'
	fi
done

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for version in "${versions[@]}"; do
	eval arches=\( \${arches_${version}[@]} \)
	for arch in "${arches[@]}"; do
		dir="$version/$arch"
		tarball="$dir/rootfs.tar.xz"
		commit="$(git log -1 --format='format:%H' "${branches[@]}" -- "$tarball")"
		branch=
		for b in "${branches[@]}"; do
			if git merge-base --is-ancestor "$commit" "$b" &> /dev/null; then
				branch="$b"
				break
			fi
		done
		if [ -z "$branch" ]; then
			echo >&2 "error: cannot determine branch for $tarball (commit $commit)"
			exit 1
		fi

		versionAliases=()
		if [ -z "${noVersion[$version]}" ]; then
			fullVersion="$(git show "$commit:$tarball" | tar -xvJ etc/debian_version --to-stdout 2>/dev/null || true)"
			if [ -z "$fullVersion" ] || [[ "$fullVersion" == */sid ]]; then
				fullVersion="$(eval "$(git show "$commit:$tarball" | tar -xvJ etc/os-release --to-stdout 2>/dev/null || true)" && echo "$VERSION" | cut -d' ' -f1)"
				if [ -z "$fullVersion" ]; then
					# lucid...
					fullVersion="$(eval "$(git show "$commit:$tarball" | tar -xvJ etc/lsb-release --to-stdout 2>/dev/null || true)" && echo "$DISTRIB_DESCRIPTION" | cut -d' ' -f2)" # DISTRIB_DESCRIPTION="Ubuntu 10.04.4 LTS"
				fi
			else
				while [ "${fullVersion%.*}" != "$fullVersion" ]; do
					versionAliases+=( $fullVersion )
					fullVersion="${fullVersion%.*}"
				done
			fi
			if [ "$fullVersion" != "$version" ]; then
				versionAliases+=( $fullVersion )
			fi
		fi
		versionAliases+=( $version $(git show "$commit:$dir/suite" 2>/dev/null || true) ${aliases[$version]} )

		echo
		cat <<-EOE
			Tags: $(join ', ' "${versionAliases[@]}")
			GitFetch: refs/heads/$branch
			GitCommit: $commit
			Directory: $dir
		EOE

		if [ "$(git show "$commit:$dir/backports/Dockerfile" 2>/dev/null || true)" ]; then
			versionBackportsAliases=( $version-backports-$arch )
			[ "$arch" == "amd64" ] && versionBackportsAliases+=( $version-backports )
			echo
			cat <<-EOE
				Tags: $(join ', ' "${versionBackportsAliases[@]}")
				GitFetch: refs/heads/$branch
				GitCommit: $commit
				Directory: $dir/backports
			EOE
		fi
	done
done

dockerfilesBase='https://github.com/tianon/dockerfiles'
dockerfilesGit="$dockerfilesBase.git"
dockerfilesBranch='master'
dockerfiles="$dockerfilesBase/commits/$dockerfilesBranch/debian"

rcBuggyCommit="$(curl -fsSL "$dockerfiles/rc-buggy/Dockerfile.atom" | tac|tac | awk -F '[ \t]*[<>/]+' '$2 == "id" && $3 ~ /Commit/ { print $4; exit }')"
experimentalCommit="$(curl -fsSL "$dockerfiles/experimental/Dockerfile.atom" | tac|tac | awk -F '[ \t]*[<>/]+' '$2 == "id" && $3 ~ /Commit/ { print $4; exit }')"

cat <<-EOE

	# sid + rc-buggy
	Tags: rc-buggy
	GitRepo: $dockerfilesGit
	GitFetch: refs/heads/$dockerfilesBranch
	GitCommit: $rcBuggyCommit
	Directory: debian/rc-buggy

	# unstable + experimental
	Tags: experimental
	GitRepo: $dockerfilesGit
	GitFetch: refs/heads/$dockerfilesBranch
	GitCommit: $experimentalCommit
	Directory: debian/experimental
EOE
