#!/usr/bin/env perl
use utf8;

use constant COPYRIGHT => <<END;

#    Copyright © 2013 Olivier Mengué
#    Original source code is available at https://github.com/dolmen/angel-PS1
#
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as
#    published by the Free Software Foundation, either version 3 of the
#    License, or (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

END

use 5.010;
use strict;
use warnings;

# Only to fail early if the tool is missing
use App::FatPacker ();
use Carp 'croak';
use File::Copy 'copy';
use Git::Sub qw(rev-parse ls-tree hash-object mktree commit commit-tree update-ref tag);
use Getopt::Long qw(:config posix_default no_ignore_case auto_help);

my ($make_release, $fake_release);

GetOptions(
    'r|release' => \$make_release,
    'n' => \$fake_release,
) or die;



# Create the script

open my $script, '>:utf8', 'angel-PS1';
print $script "#!/usr/bin/perl\n", COPYRIGHT;
close $script;
open $script, '>>:raw', 'angel-PS1';
print $script App::FatPacker->fatpack_file('bin/angel-PS1');
close $script;

chmod 0755, 'angel-PS1';

unless ($make_release) {
    say 'Done.';
    exit 0
}

# TODO check if some untracked files exist in lib/ (because they have been
# merged by the fatpacking process) and fail.


(my $version = do {
    open my $version_output, '-|', 'perl angel-PS1 --version' or die $!;
    my $line = <$version_output>;
    chomp $line;
    (split / /, $line)[2]
}) or die "Can't get version!\n";
print "Building release $version...\n";

if (-e ".git/refs/tags/v$version") {
    die "version $version already exists!\n";
}

my %new_files = map { ($_ => undef) } (
    'angel-PS1',
);

# TODO store the list of files that must not be copied from devel to release in the .gitignore of
# the release branch.
my %ignored_file = map { ($_ => 1) } qw(
    bin
    lib
    build.pl
    dist.ini
);
my %preserved_file = map { ($_ => 1) } qw(
    .gitignore
    .travis.yml
);

my ($devel_commit) = git::rev_parse 'devel';
say "devel: $devel_commit";
my ($release_commit) = git::rev_parse 'release';
say "release: $release_commit";

my %devel_tree;
git::ls_tree $devel_commit, sub {
    my ($mode, $type, $object, $file) = split;
    return if exists $ignored_file{$file} || exists $preserved_file{$file};
    $devel_tree{$file} = [ $mode, $type, $object ];
};

my %release_tree;
my %updated_files;
git::ls_tree $release_commit, sub {
    my ($mode, $type, $object, $file) = split / |\t/;
    # Merge files updated in devel
    return if $ignored_file{$file}; # This file/dir has its own life on each branch
    my $d = delete $devel_tree{$file};
    $release_tree{$file} = [ $mode, $type, $object ];
    if (exists $preserved_file{$file}) {
        say "- $file: $object (preserved)";
    } elsif ( ! $d) {
        unless (exists $new_files{$file}) {
            say "- $file: - (removed)";
            delete $release_tree{$file};
        }
    } elsif ( $object ne $d->[2]) {
        say "- $file: $object (updated)";
        $release_tree{$file} = $d;
        $updated_files{$file} = 1;
    } else {
        say "- $file: $object";
    }
};

foreach my $file (sort keys %devel_tree) {
    my $f = delete $devel_tree{$file};
    say "- $file: $f->[2] (added)";
    $release_tree{$file} = $f;
}


# Create the objects file for each new file and replace them
foreach my $file (sort keys %new_files) {
    # TODO
    my $object = git::hash_object -w => $file;
    if ($object ne $release_tree{$file}[2]) {
	say "- $file: $object (updated)";
	$release_tree{$file}[2] = $object;
	$updated_files{$file} = 1;
    }
}

die "no updated files!\n" unless %updated_files;


die "angel-PS1 updated but version unchanged!\n"
    if $updated_files{'angel-PS1'} && ! $version;


# Build the new tree object for release
my $new_release_tree = git::mktree -z =>
\(
    join(
	'',
	map { sprintf("%s %s %s\t%s\0", @{$release_tree{$_}}, $_) }
	    keys %release_tree
    )
);
say "new release tree: $new_release_tree";

# Create the release commit
# TODO use the "author" of devel as the committer
# TODO use more content in the commit message (ask interactively)
my $new_release_commit =
    git::commit_tree $new_release_tree,
		       -p => $release_commit,
		       -p => $devel_commit,
		       # For maximum compat, don't use '-m' but STDIN
		       \($version
			    ? "Release v$version"
			    : "Update ".join(', ', sort keys %updated_files));


say "new release commit: $new_release_commit";

exit 0 if $fake_release;

git::update_ref 'refs/heads/release' => $new_release_commit, $release_commit;

if ($version) {
    git::tag -a =>
             -m => "Release v$version",
             "v$version",
             $new_release_commit;
}

say 'Done.';

# vim:set et ts=8 sw=4 sts=4:
