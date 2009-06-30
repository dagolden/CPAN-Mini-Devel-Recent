package CPAN::Mini::Devel::Recent;
use 5.006;
use strict;
use warnings;
our $VERSION = '0.01'; 
$VERSION = eval $VERSION; ## no critic

use Config;
use CPAN::Mini;
use CPAN (); 
use CPAN::Tarzip;
use CPAN::HandleConfig;
use File::Temp 0.20;
use File::Spec;
use File::Path ();
use File::Basename qw/basename/;
use File::Rsync::Mirror::Recent;

our @ISA = 'CPAN::Mini';

#--------------------------------------------------------------------------#
# globals
#--------------------------------------------------------------------------#

my $tmp_dir = File::Temp->newdir( 'CPAN-Mini-Devel-Recent-XXXXXXX', 
    DIR => File::Spec->tmpdir,
);

#--------------------------------------------------------------------------#
# Extend index methods to mirror RECENT* files
#--------------------------------------------------------------------------#

my @recent_files = qw(
  authors/RECENT-1h.yaml
  authors/RECENT-6h.yaml
  authors/RECENT-1d.yaml
  authors/RECENT-1W.yaml
  authors/RECENT-1M.yaml
  authors/RECENT-1Q.yaml
  authors/RECENT-1Y.yaml
  authors/RECENT-Z.yaml
);

sub _fixed_mirrors {
    my $self = shift;
    return (@recent_files, $self->SUPER::_fixed_mirrors);
}

#--------------------------------------------------------------------------#
# Replace _get_mirror_list to add developer versions
#--------------------------------------------------------------------------#

sub _get_mirror_list {
        my $self  = shift;

    ## CPAN::Mini::Devel::Recent addition using find-ls.gz
    my $recent =  File::Spec->catfile(
        $self->{scratch},
        qw(authors RECENT-1h.yaml)
    );

    my $packages = File::Spec->catfile(
        $self->{scratch},
        qw(modules 02packages.details.txt.gz)
    );
    
    return $self->_parse_module_index( $packages, $recent );
}

#--------------------------------------------------------------------------#
# private variables and functions
#--------------------------------------------------------------------------#

my $module_index_re = qr{
    ^\s href="\.\./authors/id/./../    # skip prelude 
    ([^"]+)                     # capture to next dquote mark
    .+? </a>                    # skip to end of hyperlink
    \s+                         # skip spaces
    \S+                         # skip size
    \s+                         # skip spaces
    (\S+)                       # capture day
    \s+                         # skip spaces
    (\S+)                       # capture month 
    \s+                         # skip spaces
    (\S+)                       # capture year
}xms; 

my %months = ( 
    Jan => '01', Feb => '02', Mar => '03', Apr => '04', May => '05',
    Jun => '06', Jul => '07', Aug => '08', Sep => '09', Oct => '10',
    Nov => '11', Dec => '12'
);

# standard regexes
# note on archive suffixes -- .pm.gz shows up in 02packagesf
my %re = (
    perls => qr{(?:
                  /(?:emb|syb|bio)?perl-\d 
                | /(?:parrot|ponie|kurila|Perl6-Pugs)-\d 
                | /perl-?5\.004 
                | /perl_mlb\.zip 
    )}xi,
    archive => qr{\.(?:tar\.(?:bz2|gz|Z)|t(?:gz|bz)|(?<!ppm\.)zip|pm.gz)$}i,
    target_dir => qr{
        ^(?:
            modules/by-module/[^/]+/./../ | 
            modules/by-module/[^/]+/ | 
            modules/by-category/[^/]+/[^/]+/./../ | 
            modules/by-category/[^/]+/[^/]+/ | 
            authors/id/./../ 
        )
    }x,
    leading_initials => qr{(.)/\1./},
);

# match version and suffix
$re{version_suffix} = qr{([-._]v?[0-9].*)?($re{archive})};

# split into "AUTHOR/Name" and "Version"
$re{split_them} = qr{^(.+?)$re{version_suffix}$};

# matches "AUTHOR/tarball.suffix" or AUTHOR/modules/tarball.suffix
# and not other "AUTHOR/subdir/whatever"

# Just get AUTHOR/tarball.suffix from whatever file name is passed in
sub _get_base_id { 
    my $file = shift;
    my $base_id = $file;
    $base_id =~ s{$re{target_dir}}{};
    return $base_id;
}

sub _base_name {
    my ($base_id) = @_;
    my $base_file = basename $base_id;
    my ($base_name, $base_version) = $base_file =~ $re{split_them};
    return $base_name;
}

#--------------------------------------------------------------------------#
# _parse_module_index
#
# parse index and return array_ref of distributions in reverse date order
#--------------------------------------------------------------------------#-

sub _parse_module_index {
    my ($self, $packages, $recent ) = @_;

        # first walk the packages list
    # and build an index

    my (%valid_bases, %valid_distros, %mirror);
    my (%latest, %latest_dev);

    my $gz = Compress::Zlib::gzopen($packages, "rb")
        or die "Cannot open package list: $Compress::Zlib::gzerrno";

    $self->trace( "Scanning 02packages.details ...\n" );
    my $inheader = 1;
    while ($gz->gzreadline($_) > 0) {
        if ($inheader) {
            $inheader = 0 unless /\S/;
            next;
        }

        my ($module, $version, $path) = split;
        next if $self->_filter_module({
                module  => $module,
                version => $version,
                path    => $path,
            });
        
        my $base_id = _get_base_id("authors/id/$path");
        $valid_distros{$base_id}++;
        my $base_name = _base_name( $base_id );
        if ($base_name) {
            $latest{$base_name} = {
                datetime => 0,
                base_id => $base_id
            };
        }
    }

#    use DDS;
#    $self->trace("Distros\n");
#    Dump \%valid_distros;
#    $self->trace("Bases\n");
#    Dump \%valid_bases;

    # next walk the recent list
    $self->trace( "Scanning RECENT files for dev releases ...\n" );
    my $rr = File::Rsync::Mirror::Recent->new( local => $recent );
    my $records = $rr->news;

    my @epoch_order = sort { $records->[$a]{epoch} <=> $records->[$b]{epoch} } 
                      0 .. @$records - 1;
    
    my %living;
    for my $i ( @epoch_order ) {
      my $rec = $records->[$i];
      if ( $rec->{type} eq 'new' ) {
        $living{$rec->{path}} = 1;
      }
      elsif ( $rec->{type} eq 'delete' ) {
        $living{$rec->{path}} = 0;
      }
    }

    for my $i ( @epoch_order ) {
        next unless $living{$records->[$i]{path}};
        my %stat;
        @stat{qw/name datetime type/}=@{$records->[$i]}{qw/path epoch type/};
        
        # skip things that aren't a tarball
        next unless $stat{name} =~ $re{target_dir};
        next unless $stat{name} =~ $re{archive};

        # skip if not AUTHOR/tarball 
        # skip perls
        my $base_id = _get_base_id($stat{name});
        next unless $base_id; 
        
        next if $base_id =~ $re{perls};

        my $base_name = _base_name( $base_id );

        # if $base_id matches 02packages, then it is the latest version
        # and we definitely want it; also update datetime from the initial
        # assumption of 0
        if ( $valid_distros{$base_id} ) {
            $mirror{$base_id} = $stat{datetime};
            next unless $base_name;
            if ( $stat{datetime} > $latest{$base_name}{datetime} ) {
                $latest{$base_name} = { 
                    datetime => $stat{datetime}, 
                    base_id => $base_id
                };
            }
        }
        # if not in the packages file, we only want it if it resembles 
        # something in the package file and we only the most recent one
        else {
            # skip if couldn't parse out the name without version number
            next unless defined $base_name;

            # skip unless there's a matching base from the packages file
            next unless $latest{$base_name};

            # keep only the latest
            $latest_dev{$base_name} ||= { datetime => 0 };
            if ( $stat{datetime} > $latest_dev{$base_name}{datetime} ) {
                $latest_dev{$base_name} = { 
                    datetime => $stat{datetime}, 
                    base_id => $base_id
                };
            }
        }
    }

    # pick up anything from packages we didn't already get (shouldn't happen)
    for my $name ( keys %latest ) {
        my $base_id = $latest{$name}{base_id};
        $mirror{$base_id} = $latest{$name}{datetime} unless $mirror{$base_id};
    }
          
    # for dev versions, it must be newer than the latest version of
    # the same base name from the packages file

    for my $name ( keys %latest_dev ) {
        if ( ! $latest{$name} ) {
            $self->trace( "Shouldn't be missing '$name' matching '$latest_dev{$name}{base_id}'\n" );
            next;
        }
        next if $latest{$name}{datetime} > $latest_dev{$name}{datetime};
        $mirror{ $latest_dev{$name}{base_id} } = $latest_dev{$name}{datetime} 
    }

    my $mirror_list =
        [ sort map { s{^(((.).).+)$}{authors/id/$3/$2/$1}; $_ } keys %mirror ];

    return $mirror_list;
}

1; #modules must return true

__END__

#--------------------------------------------------------------------------#
# pod documentation 
#--------------------------------------------------------------------------#

=begin wikidoc

= NAME

CPAN::Mini::Devel::Recent - Create CPAN::Mini mirror with recent developer releases

= VERSION

This documentation describes version %%VERSION%%.

= SYNOPSIS

    $ minicpan -c CPAN::Mini::Devel::Recent

= DESCRIPTION

CPAN::Mini::Devel::Recent is similar to [CPAN::Mini::Devel], except it
uses the new, experimental {RECENT-*} index files on CPAN, which are updated
more frequently than {indices/find-ls.gz} file.

Normally, [CPAN::Mini] creates a minimal CPAN mirror with the latest version of
each distribution, but excluding developer releases (those with an underscore
in the version number, like 0.10_01).

CPAN::Mini::Devel::Recent enhances CPAN::Mini to include the latest developer and
non-developer release in the mirror. For example, if Foo-Bar-0.01,
Foo-Bar-0.02, Foo-Bar-0.03_01 and Foo-Bar-0.03_02 are on CPAN, only
Foo-Bar-0.02 and Foo-Bar 0.03_02 will be mirrored. This is particularly useful
for creating a local mirror for smoke testing.

Unauthorized releases will also be included if they resemble a distribution
name already in the normal CPAN packages list.

There may be errors retrieving very new modules if they are indexed but not
yet synchronized on the mirror.

= USAGE

See [Mini::CPAN].

= BUGS

Please report any bugs or feature using the CPAN Request Tracker.  
Bugs can be submitted through the web interface at 
[http://rt.cpan.org/Dist/Display.html?Queue=CPAN-Mini-Devel-Recent]

When submitting a bug or request, please include a test-file or a patch to an
existing test-file that illustrates the bug or desired feature.

= SEE ALSO

* [CPAN::Mini]
* [CPAN::Mini::Devel]

= AUTHOR

David A. Golden (DAGOLDEN)

= COPYRIGHT AND LICENSE

Copyright (c) 2009 by David A. Golden

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
[http://www.apache.org/licenses/LICENSE-2.0]

Files produced as output though the use of this software, shall not be
considered Derivative Works, but shall be considered the original work of the
Licensor.

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=end wikidoc

=cut