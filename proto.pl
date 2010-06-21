#!/usr/bin/perl -w

=head1 NAME

proto.pl - create and maintain a Perl 6 software environment

=head1 SYNOPSIS

    # Perl 5 must already be installed - ensure that it's >= v5.8
    perl -v

    # Fetch the proto bootstrap file this way, or with a browser:
    # (all on one line without the \ if not in a Unix compatible shell)
    perl -MLWP::UserAgent -e"LWP::UserAgent->new->mirror( \
        'http://github.com/masak/proto/raw/master/proto', 'proto.pl')"

    # Create your default ~/.perl6/proto/proto.conf
    perl proto.pl configure proto

    # After optionally editing proto.conf, do the bootstrap installation
    perl proto.pl install rakudo

    # Proto suggests you make 'proto', 'rakudo' and 'perl6' commands
    sudo perl proto.pl setup commands

    # If the installation appears successful, verify that it works
    perl proto.pl selftest                              # TODO

    # Read the fine manuals
    perl proto.pl help
    perl proto.pl help install
    perldoc proto.pl

    # Use proto to install modules
    perl proto.pl install SVG HTTP::Daemon:auth<mberends>  # TODO

=cut

use strict;
$| = 1; # flush after every print

use Archive::Extract;  # because releases are in .tar.gz format
use Cwd;               # to return to original directory after a chdir
use File::Spec;        # OS independent volume, directory and file names
use LWP::UserAgent;    # mirror() downloads tarballs and files

#---------------------------- main program -----------------------------
help( @ARGV ); # if requested, displays help and exits
my ($config_file, $state_file) = get_config_file_names();
if ( "@ARGV" eq 'configure proto' ) {
    if ( -f $config_file ) {
        die "cannot configure: file '$config_file' already exists\n";
    }
    create_default_config_file($config_file);
}
unless ( -f $config_file ) {
    die "first use '$0 configure proto' to create $config_file";
}
create_default_state_file( $state_file ) unless ( -f $state_file );
my ( $config_info, $commentinfo ) = load_config_file($config_file);
create_directories( $config_info->{'Perl 6 library'},
    $config_info->{'Proto projects cache'} );
if ( "@ARGV" eq 'install rakudo' ) { install_rakudo($config_info); }
if ( "@ARGV" eq 'upgrade rakudo' ) { upgrade_rakudo($config_info); }
make_pir_modules( $config_info );
exec( $config_info->{'Perl 6 executable'} .
    ' -e"use Installer; Installer.new.subcommand-dispatch(@*ARGS.shift).(@*ARGS)" '
     . "@ARGV" );

#--------------------------- install_rakudo ----------------------------
sub install_rakudo {
    my ($config_info) = @_;
    my $perl6 = $config_info->{'Perl 6 executable'};
    if ( -x $perl6 ) {
        die "$0 will not install rakudo because it is already installed\n";
    }
    print "proto is installing Rakudo Perl 6.\n";
    download_rakudo( $config_info ) and
    download_parrot( $config_info ) and
    build_parrot(    $config_info ) and
    build_rakudo(    $config_info );
    # Perform a minimal check that the installation succeeded
    unless ( -x $perl6 ) {
        die "proto was unable to install Rakudo Perl 6 :-(\n";
    }
    my $output = qx{$perl6 -e"say 'Perl 6 rocks!'"};
    unless ( $output eq "Perl 6 rocks!\n" ) {
        die "perl 6 install error: $!";
    }
    print "Rakudo Perl 6 has been installed.  " .
        "Create a path or shortcut to:\n\n    $perl6 \n\n" .
        "You can also use '$0 help' or '$0 setup commands' to proceed\n";
    exit; # do nothing else after installing Rakudo
}

#--------------------------- download_rakudo ---------------------------
sub download_rakudo {
    my ( $config_info ) = @_;
    my $rakudo_build_dir = $config_info->{'Rakudo build directory'};
    create_directories( $rakudo_build_dir );
    my $rakudo_version = $config_info->{'Rakudo version'};
    if ( $rakudo_version =~ m/ \d{4}\.\d{2} /x ) {
        my $rakudo_release_tarfile = "rakudo-$rakudo_version.tar.gz";
        my $filename = File::Spec->catfile(
            $rakudo_build_dir,
            $rakudo_release_tarfile
        );
        if ( -f $filename ) {
            my $filesize = -s ( $filename );
            print "$rakudo_release_tarfile already downloaded ($filesize bytes)\n";
        }
        else {
            print "proto is downloading a $rakudo_release_tarfile...\n";
            my $ua = LWP::UserAgent -> new;
            $ua->show_progress( 1 );
            my $url = "http://cloud.github.com/downloads/rakudo/rakudo/$rakudo_release_tarfile";
            print "filename = $filename\n";
            $ua->mirror( $url, $filename );
        }
        my $ae = Archive::Extract->new( archive => $filename );
        $ae->extract( to => $rakudo_build_dir )
            or die "cannot extract from archive";
    }
    elsif ($rakudo_version eq 'bleeding') {
        if ( -d $rakudo_build_dir ) {
            if ( system("$^X -MExtUtils::Command -e rm_rf $rakudo_build_dir") != 0 ) {
                die "Couldn't remove $rakudo_build_dir";
            }
        }
        my $log_directive = '> rakudo-download.log 2> rakudo-download.err';
        my $command = qq{git clone git://github.com/rakudo/rakudo.git "$rakudo_build_dir" $log_directive};
        if ( system( $command ) != 0 ) {
            die "Downloading Rakudo using git clone failed";
        }
    }
    else {
        die "Rakudo version was neither 'bleeding' nor a number like '2010.02'";
    }

    print "Rakudo download ok\n";
    return 1;
}

#--------------------------- download_parrot ---------------------------
sub download_parrot {
    my ($config_info) = @_;
    my $parrot_build_dir = $config_info->{'Parrot build directory'};
    $parrot_build_dir = make_short_path( $parrot_build_dir );
    create_directories( $parrot_build_dir );
    my $parrot_version = $config_info->{'Parrot version'};
    if ( $parrot_version eq 'Rakudo-decides' ) {
        # Rakudo has already been downloaded. Read build/PARROT_REVISION
        my $version_filename = File::Spec->catfile(
            $config_info->{'Rakudo build directory'}, 'build',
            'PARROT_REVISION'
        );
        open my $version_file, '<', $version_filename
            or die "$0 cannot open $version_filename: $!";
        my $version_line = <$version_file>;
        close $version_file;
        $version_line =~ m/ (\d+) /x
            or die "$0 cannot extract Parrot version: $!";
        $parrot_version = $1;
    }
    if ( $parrot_version =~ m/\d+\.\d+\.\d+/x ) {
        # a Parrot release, either development or supported
        my $parrot_tarfile = "parrot-$parrot_version.tar.gz";
        my $filename = File::Spec->catfile( $parrot_build_dir, $parrot_tarfile );
        # check whether a download has already been done, skip if ok
        if ( -f $filename ) {
            my $filesize = -s ( $filename );
            print "$parrot_tarfile is already downloaded ($filesize bytes)\n";
        }
        else {
            print "proto is downloading $parrot_tarfile...\n";
            my $ua = LWP::UserAgent -> new;
            $ua->show_progress( 1 );
            # Parrot now makes every third release a "supported" one
            
            my $release_path = 'releases/devel';
            if ( $parrot_version =~ m/ ^ \d+ \. (3|6|9|12) \. \d+ $ /x ) {
                $release_path = 'releases/supported';
            }
            my $url = "http://ftp.parrot.org/$release_path/$parrot_version/$parrot_tarfile";
            my $response = $ua->mirror( $url, $filename );
            $response->is_success or die "cannot download $url";
            print "downloaded.\n";
        }
        # check whether an extract has already been done, skip if ok
        #my $parrot_build_dir = $config_info->{'Parrot build directory'};
        my $parrot_version_file = File::Spec->catfile( $parrot_build_dir,
            "parrot-$parrot_version", "VERSION" );
        if ( -f $parrot_version_file ) {
            print "Parrot source code was already extracted\n";
        }
        else {
            print "extracting $filename...\n";
            my $ae = Archive::Extract->new( archive => $filename );
            $ae->extract( to => $parrot_build_dir )
                or die "cannot extract from archive";
        }
    }
    elsif ( $parrot_version =~ m/ ^ \d{5,6} $ /x or $parrot_version eq 'HEAD' ) {
        # use Subversion to checkout a Parrot revision such as 45370
        # TODO: detect if Subversion missing, and install.
        my $svn_version = qx{svn --version};
        $svn_version =~ s/^svn.*?([0-9.]+).*/subversion $1/s;   # huge re-format
        # or install from http://subversion.apache.org/packages.html#windows
        my $revision_option = " --revision $parrot_version";
        print "proto is checking out Parrot $parrot_version...";
        my $log_directive = '> parrot-download.log 2> parrot-download.err';
        my $command = qq{svn checkout$revision_option https://svn.parrot.org/parrot/trunk "$parrot_build_dir"$log_directive};
        print "\nsvn command = $command\n";
        if ( system( $command ) != 0 ) {
            die "subversion checkout of Parrot failed";
        }
    }
    else {
        die "\nThe Parrot version is $parrot_version" .
            " but should be 'Rakudo-decides', 'HEAD' or a number such as '2.2.0'";
    }
    # TODO: verify the download and die noisily if it seems wrong
    print "parrot download done\n";
    return 1;
}

#---------------------------- build_parrot -----------------------------
sub build_parrot {
    my ($config_info) = @_;
    print "proto is building Parrot...";
    my $cwd = Cwd->getcwd();
    my $parrot_build_dir   = $config_info->{'Parrot build directory'};
    my $parrot_install_dir = $config_info->{'Parrot install directory'};
    my $parrot_version     = $config_info->{'Parrot version'};
    if ( $parrot_version =~ m/\d+\.\d+\.\d+/x ) { # for example "2.2.0"
        $parrot_build_dir = File::Spec->catdir( 
            $parrot_build_dir,
            "parrot-$parrot_version"
        );
    }
    elsif ( $parrot_version ne 'Rakudo-decides' and $parrot_version ne 'HEAD'
            and $parrot_version !~ m/ ^ \d{5,6} $ /x ) {
        die "\nThe Parrot version is '$parrot_version' but should be " .
            "'Rakudo-decides', 'HEAD', a revision such as 45822 or a " .
            "release such as '2.3.0'";
    }
    chdir $parrot_build_dir or die "cannot chdir";
    unless ( -f 'Makefile' ) {
        my $prefix  = $config_info->{'Parrot install directory'};
        $prefix = make_short_path( $prefix );
        $prefix =~ s/\\/\//g; # ugh. change backslashes to forward slashes.
        my @parrot_options = ( "--prefix=\"$prefix\"" );
        if ( $^O ne "MSWin32" ) {
            push @parrot_options, "--optimize";  # or does this also work on Windows now?
        }
        # run Parrot's Configure.pl
        my $log_directive = '> proto-configure.log 2> proto-configure-error.log';
        my $command = "$^X Configure.pl @parrot_options $log_directive";
        if ( system( $command ) != 0 ) {
            die "could not configure Parrot, see parrot/proto-configure-error.log";
        }
    }
    # run Parrot's make
    my $log_directive = '> proto-make.log 2> proto-make-error.log';
    my $make = $config_info->{'Make utility'};
    my $command = "$make install $log_directive";
    if ( system( $command ) != 0 ) {
        die "proto got an error while bulding Parrot, see parrot/proto-make-error.log";
    }
    chdir $cwd;
    # TODO: run a 'parrot --version' and verify the correct output, die noisily if wrong
    print "building Parrot done\n";
    return 1;
}

#---------------------------- build_rakudo -----------------------------
sub build_rakudo {
    my ($config_info) = @_;
    my $rakudo_build_dir = $config_info->{'Rakudo build directory'};
    my $rakudo_version = $config_info->{'Rakudo version'};
    my $parrot_install_dir = $config_info->{'Parrot install directory'};
    if ( $rakudo_version =~ m/ \d{4}\.\d{2} /x ) { # for example 2010.03
        # versions like '2010.03' are release tarballs
        $rakudo_build_dir = File::Spec->catdir(
            $rakudo_build_dir,
            "rakudo-$rakudo_version"
        );
    }
    elsif ($rakudo_version ne 'bleeding') {
        die "Rakudo version was neither 'bleeding' nor a number like '2010.03'";
    }
    my $rakudo_build_log = File::Spec->catfile(
        $rakudo_build_dir, '', 'rakudo-build.log'
    );
    if ( ! -f "$rakudo_build_dir/perl6" ) {
        print "Building Rakudo in $rakudo_build_dir...\n";
        my $cwd = Cwd->getcwd();
        chdir $rakudo_build_dir or die "cannot chdir";
        my $parrot_config = File::Spec->catfile(
            $parrot_install_dir, 'bin', 'parrot_config'
        );
        $parrot_config = make_short_path( $parrot_config );
        my @rakudo_options = ( qq{--parrot-config="$parrot_config"} );
        my $log_directive = '> proto-configure.log 2> proto-configure-error.log';
        my $command = "$^X Configure.pl @rakudo_options $log_directive";
        # print "Rakudo Configure command = $command\n";
        if ( system( $command ) != 0 ) {
            die "error configuring Rakudo: $!";
        }
        $log_directive = '> proto-make.log 2> proto-make-error.log';
        my $make = $config_info->{'Make utility'};
        $command = "$make install $log_directive";
        if ( system( $command ) != 0 ) {
            die "cannot run '$command': $!";
        }
        print "\nBuilding Rakudo done\n";
        chdir $cwd;
    }
    return 1;
}

#--------------------------- upgrade_rakudo ----------------------------
sub upgrade_rakudo {
    my ($config_info) = @_;
    unless ( -x $config_info->{'Perl 6 executable'} ) {
        die "cannot upgrade, you should first install rakudo";
    }
    if ( $config_info->{'Rakudo version'} eq 'bleeding' ) {
        print "Upgrading bleeding edge Rakudo\n";
    }
    else {
        print "Upgrading release Rakudo\n";
    }
    exit;
}

#-------------------------- make_pir_modules ---------------------------
sub make_pir_modules {
    my ( $config_info ) = @_;
    # Copy the modules of proto itself from the local lib directory to
    # ~/.perl6/lib, and then compile to .pir format.
    # TODO: multiple versions of the Ecosystem and Installer modules
    my $perl6 = $config_info->{'Perl 6 executable'};
    my $perl6libdir = $config_info->{'Perl 6 library'};
    my $displayed_building = 0;
    # Precompile these modules to PIR
    for my $name ( 'Configure', 'Ecosystem', 'Installer' ) {
        my $module_install_path = File::Spec->catfile(
            $perl6libdir, "$name.pm6"
        );
        my $module_local_path = File::Spec->catfile(
            'lib', "$name.pm6"
        );
        # If it is newer or has not been copied, copy "$name.pm6" from
        # "lib/" to "$perl6libdir/".
        # -M is script start time minus file modification time, in days.
        if ( ! -f $module_install_path || -M $module_local_path < -M $module_install_path ) {
            unless ( $displayed_building ) {
                print "Building proto..."; $displayed_building = 1;
            }
            # warn "copying $name to $perl6libdir\n";
            if ( -f $module_local_path ) {
                system( qq{perl -MExtUtils::Command -e cp "$module_local_path" "$module_install_path"} );
                # Maybe the main proto script (written in Perl 5) would have
                # been able to load the ExtUtils::Command module anyway, and
                # could have done the mkdir and cp commands internally...
                # Such usage is not documented.
            }
            else {
                # download the module file from github.
                print "downloading $name.pm6...\n";
                my $ua = LWP::UserAgent -> new;
                $ua->show_progress( 1 );
                my $url = "http://github.com/masak/proto/raw/master/lib/$name.pm6";
                print "module_install_path = $module_install_path\n";
                $ua->mirror( $url, $module_install_path );
            }
        }
        if ( ! -f "$perl6libdir/$name.pir" || -M "$perl6libdir/$name.pm6" < -M "$perl6libdir/$name.pir" || -M $perl6 < -M "$perl6libdir/$name.pir" ) {
            unless ( $displayed_building ) {
                print "Building proto..."; $displayed_building = 1;
            }
            # warn "compiling $perl6libdir/$name.pir\n";
            system( qq{$perl6 --target=pir --output=$perl6libdir/$name.pir $perl6libdir/$name.pm6} );
        }
    }
    if ( $displayed_building ) {
        print "done\n";
    }
}

#------------------------- detect_make_utility -------------------------
sub detect_make_utility {
    my @make_utilities = (
        [ 'make',         '--version' ],
        [ 'nmake',        '/HELP'     ],
        [ 'mingw32-make', '--version' ]
    );
    my $make_utility;
    for my $make ( @make_utilities ) {
        my ( $command, $arguments ) = @{$make};
        if ( system( "$command $arguments" ) == 0 ) {
            $make_utility = $command;
            last;
        }
    }
    return $make_utility;
}

#------------------------- create_directories --------------------------
sub create_directories {
    # Create a list of directories if they do not yet exist
    # It would have been nice to use File::Path->make_path here, but in
    # Windows, "make_path .perl6" dies with "invalid path"
    for my $path ( @_ ) {
        # skip all the inner work if $path already exists
        unless ( -d $path ) {
            my ( $volume, $directories, $file ) = File::Spec->splitpath( $path, 1 );
            my @dirs = File::Spec->splitdir( $directories );
            # Because this uses mkdir, it must verify or create the
            # directories one by one.
            for my $depth ( 0 .. $#dirs ) {
                my $subpath = File::Spec->catdir( @dirs[0..$depth] );
                my $subdir = File::Spec->catpath( $volume, $subpath, '' );
                unless ( -d $subdir ) {
                    print "Making $subdir\n";
                    if ( ( mkdir $subdir ) == 0 ) {
                        die "Cannot create directory $path";
                    }
                }
            }
        }
    }
}

#--------------------------- make_short_path ---------------------------
# BUG: the Parrot "$make install" target used below, runs
# 'perl tools/dev/install_files.pl' and passes a series of parameters
# that are separated by spaces.  The parameters should be quoted in case
# they contain spaces, but they are not.
# The result is that Windows XP users, whose home directories are
# typically "C:\Documents and Settings\Username", end up with the
# non existent directory name "C:\Documents" being passed, followed by
# the bare words "and" and "Settings".  The result is a failure to
# install Parrot.
# Parrot has these tickets to work on the problem:
#     http://trac.parrot.org/parrot/ticket/930
#     http://trac.parrot.org/parrot/ticket/888
# NOTE: attempting to bypass Parrot's Makefile, and run install_files.pl
# directly, also results in the same or similar problems.  Therefore the
# unquoted arguments are being passed lower down the Parrot toolchain.
# WORKAROUND: use the MSDOS short name instead, eg C:\DOCUME~1
# Of course on non-Windows platforms this is a useless waste of time.
sub make_short_path {
    my ($path) = @_;
    if ( $^O eq 'MSWin32' and index($path, ' ') >= 0 ) {
        # Warning: possibly unreliable code, depending on your Windows setup
        my ($volume, $directories, $file) = File::Spec->splitpath( $path, 1 );
        my @dirs = File::Spec->splitdir( $directories );
        for ( my $i=0; $i<$#dirs; $i++ ) {
            if ( index($dirs[$i], ' ') >= 0 ) {
                # this oversimplification is definitely wrong on a
                # small minority of Windows systems, but mberends--
                # cannot be bothered to do it properly.
                my $shortname = uc(substr($dirs[$i],0,6)) . '~1';
                # for example, it's not always ~1 :/
                $dirs[$i] = $shortname;
            }
        }
        $directories = File::Spec->catdir( @dirs );
        $path = File::Spec->catpath($volume, $directories, '' );
        # print "shortened $path to eliminate spaces\n";
    }
    return $path;
}

#------------------------ get_config_file_names ------------------------
sub get_config_file_names {
    # Removed File::HomeDir dependency because it is not a core module.
    # The following is the only functionality proto needed from it.
    my $home_path = $^O eq 'MSWin32'
        ? $ENV{'HOMEDRIVE'} . $ENV{'HOMEPATH'}
        : $ENV{'HOME'};
    my ( $home_vol, $home_dir ) = File::Spec->splitpath( $home_path, 1 );
    my $perl6basedir = File::Spec->catpath( $home_vol, $home_dir, '.perl6' );
    my $config_file  = File::Spec->catfile( $perl6basedir, 'proto', 'proto.conf' );
    my $state_file   = File::Spec->catfile( $perl6basedir, 'proto', 'projects.state' );
    return ($config_file, $state_file);
}

#--------------------- create_default_config_file ----------------------
sub create_default_config_file {
    my ($proto_config_file) = @_;
    # Derive all the other directories and filenames from
    # $proto_config_file (usually ~/.perl6/proto/proto.conf).
    my ($home_vol, $proto_path, $config_file) = File::Spec->splitpath( $proto_config_file );
    my @proto_dirs = File::Spec->splitdir( $proto_path );
    pop @proto_dirs if ( $proto_dirs[$#proto_dirs] eq '' ); # useless
    my @perl6_dirs = @proto_dirs[0 .. $#proto_dirs-1];
    my $perl6_dir = File::Spec->catdir( @perl6_dirs );
    my $perl6_lib_path = File::Spec->catpath( $home_vol, $perl6_dir, 'lib' );
    my $proto_cache_dir = File::Spec->catdir( @proto_dirs );
    my $proto_cache_path = File::Spec->catpath( $home_vol, $proto_cache_dir, 'cache' );
    # create directories if they do not yet exist
    create_directories( $perl6_lib_path, $proto_cache_path );
    my $rakudo_build_dir = File::Spec->catpath( $home_vol, $perl6_dir, 'rakudo' );
    my $parrot_build_dir = File::Spec->catpath( $home_vol, $perl6_dir, 'parrot' );
    my $parrot_install_dir = File::Spec->catpath( $home_vol, $perl6_dir, 'parrot_install' );
    my @proto_cache_dirs = ( @proto_dirs, 'cache' );
    my $projects_cache_dir = File::Spec->catpath( $home_vol, File::Spec->catdir(@proto_dirs), 'cache' );

    my $perl6exe;
    if ( exists( $ENV{PERL6EXE} ) ) { # if you know what you're doing
        $perl6exe = $ENV{PERL6EXE};
    }
    else { # default: install rakudo in ~/.perl6/parrot_install/bin
        my $parrot_install_bin_dir = File::Spec->catdir( @perl6_dirs, 'parrot_install', 'bin' );
        $perl6exe = File::Spec->catpath( $home_vol, $parrot_install_bin_dir, 'perl6' );
        if ( $^O eq 'MSWin32' ) { $perl6exe = make_short_path($perl6exe) . '.exe'; }
    }

    my $config_info = {
        'proto.conf version'       => '2010-04-21',
        'Rakudo version'           => '2010.04',
        'Parrot version'           => '2.3.0',
        'Proto projects cache'     => $projects_cache_dir,
        'Rakudo build directory'   => $rakudo_build_dir,
        'Parrot build directory'   => $parrot_build_dir,
        'Parrot install directory' => $parrot_install_dir,
        'Perl 6 executable'        => $perl6exe,
        'Perl 6 library'           => $perl6_lib_path,
        'Make utility'             => detect_make_utility(),
        'Test when building'       => 'no',
        'Test failure policy'      => 'die',
        'Perl 6 project developer' => 'no',
    };
    my  $commentinfo = {
        '/' => [ "$proto_config_file -- created by proto",
                 'This file contains settings as "key: value" pairs, and comments.',
                 'You are welcome -- encouraged, even -- to edit the file manually.' ],
        'proto.conf version'
            => [ 'proto.conf version -- the version number of this file.',
                 'proto uses it to determine whether the file needs to be',
                 'upgraded to a newer version. The value should never need',
                 'to be edited manually.' ],
        'Proto projects cache'
            => [ 'Proto projects cache -- the base directory in which each project',
                 'gets its own download directory' ],
        'Rakudo build directory'
            => [ 'Rakudo build directory -- Rakudo source is compiled here.' ],
        'Rakudo version'
            => [ "Rakudo version -- 'release', 'bleeding' (requires git), or a number such",
                 "as '2010.04'" ],
        'Rakudo revision'
            => [ 'Rakudo revision -- the revision of Rakudo Perl 6 to',
                 'download, if no such revision was found in $RAKUDO_DIR or',
                 'other likely locations at startup. Allowed values are',
                 '"bleeding", "release", and a hexadecimal integer of length',
                 'up to 40. The value "bleeding" means to download the latest',
                 'Rakudo Perl 6 revision from github, whereas "release" means',
                 'to download the latest release as a tarball.' ],
        'Parrot build directory'
            => [ 'Parrot build directory -- Parrot source is compiled here.' ],
        'Parrot version'
            => [ "Parrot version -- either 'HEAD' (requires subversion) or a revision",
                 "number such as 45822 (also requires subversion) or a release number",
                 "such as '2.3.0'" ],
        'Perl 6 executable'
            => [ 'Perl 6 executable -- how to run perl6, with a possible file extension' ],
        'Perl 6 library'
            => [ 'Perl 6 library -- the path to a directory, which will be created',
                 'if it does not exist, which will contain the projects installed',
                 'by proto. If you set this to a different path after projects',
                 'have already been installed, be aware that the old projects',
                 'will have to be moved along if proto is to find them' ],
        'Make utility'
            => [ 'Make utility -- the name of the command on your system that builds',
                 'Parrot, Rakudo and application projects using their Makefile.' ],
        'Test when building'
            => [ 'Test when building -- when building projects that were just',
                 'downloaded or updated, whether to also run the test suites',
                 'of those projects. This option only controls whether the',
                 'tests are actually run; the "Test failure policy"',
                 'determines whether or not to halt the build process on',
                 'a failing test suite. Values other than "yes" are treated',
                 'as "no".' ],
        'Test failure policy'
            => [ 'Test failure policy -- what to do when tests fail in the',
                 'test suites of projects that are being installed. Note that',
                 'this option has no effect unless the option "Test when',
                 'building" has been set to "yes". The value "die" of this',
                 'option means that the build process halts whenever a test',
                 'suite fails. Other values are treated as "keep going".' ],
        'Perl 6 project developer'
            => [ 'Perl 6 project developer -- yes or no.  When set, this option makes',
                 'proto try to download read-write versions of project',
                 'repositories, from which project development can be',
                 'carried out. If such a download fails, proto falls back to',
                 'downloading the project the usual way.' ],
    };
    save_config_file($proto_config_file, $config_info, $commentinfo )
        or die "Couldn't create $proto_config_file: $!\n";
    die <<"PROTO_CONFIG_MESSAGE";

*** CONFIG FILE CREATED ***

Hello!  I have made a configuration file that you may want to review,
called '$proto_config_file'.

If you're new to this, or reluctant to do configuration, you probably want
the default settings anyway. The most important ones are:
Perl 6 library         -> $config_info->{'Perl 6 library'}
Perl 6 executable      -> $config_info->{'Perl 6 executable'}

These settings will be used to bootstrap your Perl 6 software ecosystem
if you run '$0 install rakudo'.
PROTO_CONFIG_MESSAGE
}

#---------------------- create_default_state_file ----------------------
sub create_default_state_file {
    my ($file_name, @project_names ) = @_;
    my $project_dir = $config_info->{'Proto projects directory'};
    open PROJECTS_STATE, ">", $file_name or die "cannot create $file_name: $!";
    for my $project_name (@project_names) {
        my $path = "$project_dir/$project_name";
        print PROJECTS_STATE join "\n",
            "$project_name:",
            '    state: legacy',
            "    old-location: $path",
            '',
            '';
    }
    close PROJECTS_STATE;
}

#-------------------------- load_config_file ---------------------------
sub load_config_file {
    my ( $filename ) = @_;
    my $settings = {};
    my $comments = {};
    my @collected_comments = ();
    open my $CONFIG_FILE, '<', $filename
        or die "cannot open $filename for read: $!";
    my $doc_sep_line = qr/^---/;
    my $comment_line = qr/\#(.*)$/;
    my $setting_line = qr/(.*):\s+(.*)/;
    while ( my $line = <$CONFIG_FILE> ) {
        chomp $line;
        if ( $line =~ $doc_sep_line ) {
            $comments->{'/'} = [ @collected_comments ];
            @collected_comments = ();
        }
        elsif ( $line =~ $comment_line ) {
            push @collected_comments, $1;
        }
        elsif ( $line =~ $setting_line ) {
            $settings->{$1} = $2;
            $comments->{$1} = [ @collected_comments ];
            @collected_comments = ();
        }
    }
    close $CONFIG_FILE;
    return wantarray ? ( $settings, $comments ) : $settings;
}

#-------------------------- save_config_file ---------------------------
sub save_config_file {
    my ( $filename, $settings, $comments ) = @_;
    if ( not defined $comments ) { $comments = { }; }
    open my $CONFIG_FILE, '>', $filename
        or die "cannot open $filename for write: $!";
    my $main_comments = $comments->{'/'};
    if ( defined $main_comments ) {
        for my $comment ( @$main_comments ) {
            print {$CONFIG_FILE} "# $comment\n";
        }
    }
    print {$CONFIG_FILE} "--- \n";
    for my $settingname ( sort keys %$settings ) {
        print {$CONFIG_FILE} "\n";
        my $setting_comments = $comments->{$settingname};
        if ( defined $setting_comments ) {
            for my $comment ( @$setting_comments ) {
                print {$CONFIG_FILE} "# $comment\n";
            }
        }
        print {$CONFIG_FILE} "$settingname: ", ${$settings}{$settingname}, "\n";
    }
    close $CONFIG_FILE;
}

#-------------------------------- help ---------------------------------
sub help {
    my ( @argv ) = @_;
    if ( @argv == 0 ) {
        print <<END_OF_HELP;
Welcome to proto!  Give proto a command, for example:

$0 help
$0 configure proto
$0 install rakudo

END_OF_HELP
        exit;
    }
    # continue if @argv > 0
    if ( @argv == 1 and $argv[0] eq 'help' ) {
        print <<END_OF_HELP;

Use '$0 help <command>' to read more about each command:

help         display commands and their arguments
clean        remove downloaded projects from cache
configure    create proto.conf if it does not exist
fetch        download projects into cache but do not test or install
install      (only if not installed) copy to Perl 6 library directories
reconfigure  interactively change the existing proto.conf
refresh      download newer project files into cache
selftest     verify proto operation using mock drivers and data (TODO)
setup        add 'proto', 'rakudo' and 'perl6' into the search path
showdeps     show dependencies of projects
showstate    show the state of a project (fetched, built, tested)
test         check a project for correct operation
upgrade      (only if installed) fetch, test and install newer version
uninstall    erase from installation directories

END_OF_HELP
        exit;
    }
    if ( @argv == 2 and $argv[0] eq 'help' ) {
        # display help for various commands (defined alphabetically).
        # help clean
        if ( $argv[1] eq 'clean' ) {
            print <<END_OF_HELP;

$0 clean project(s)

Remove the named projects from proto's cache.  Any modules installed in
the Perl 6 library directories will remain there, use 'uninstall' to
remove a project's modules from the Perl 6 library directories.

END_OF_HELP
            exit;
        }
        # help configure
        if ( $argv[1] eq 'configure' ) {
            print <<END_OF_HELP;

$0 configure proto

Detects your Perl 6 configuration and writes default settings into proto.conf.
You can edit the file or use '$0 reconfigure proto' before proceeding.

END_OF_HELP
            exit;
        }
        # help install
        if ( $argv[1] eq 'install' ) {
            print <<END_OF_HELP;

$0 install project(s)

Does a complete fetch, build, test and install process for one or more
projects, and also any other projects these may depend on.

END_OF_HELP
            exit;
        }
        # help reconfigure
        if ( $argv[1] eq 'reconfigure' ) {
            print <<END_OF_HELP;

$0 reconfigure proto

Interactively updates an existing proto.conf file.  Proto displays each
setting name, description and value, then lets the user type in a new
value or just press Enter to keep the existing one.

END_OF_HELP
            exit;
        }
        # help setup
        if ( $argv[1] eq 'setup' ) {
            print <<END_OF_HELP;

$0 setup commands

Detects the operating system and displays the appropriate steps for you
to create 'proto', 'rakudo' and 'perl6' commands.

END_OF_HELP
            exit;
        }
        die "Sorry, proto has no help for $argv[1]\n";
    }
}

__END__

=head1 OVERVIEW

The C<proto> utility is a Perl 5 script that installs Parrot and Rakudo
Perl 6 if they are not already installed, or works with your existing
Perl 6 installation.  Proto uses its Perl 6 C<Installer> module to
download, test and install your choice of Perl 6 projects.

The Installer script loads Proto's F<Installer.pm> and F<Ecosystem.pm>
modules, and executes commands such as C<install> or C<test>.

=head1 DEPENDENCIES

Perl 5.8, a C compiler and a make utility are the minimum requirements.
Unix compatible systems generally have these already installed, or have
a package manager that can provide them.

On Windows the most popular options are Strawberry Perl (which includes
everything you need, and can download CPAN modules too) and ActiveState
Perl (which recently added the MinGW C compiler as an option, and has
its own package manager called ppm instead of cpan).  See
L<http://strawberryperl.com> or L<http://activestate.com/activeperl>.
Some Windows based developers prefer the Microsoft C++ compiler, from
L<http://www.microsoft.com/express/downloads>.

Git and Subversion are optional.  Users interested in the latest source
code of Parrot and Rakudo should install these utilities.  See
L<http://git-scm.com> and L<http://subversion.apache.org>.

The proto developers are striving to install and run Rakudo Perl 6 with
whatever operating system, Perl 5 distribution and compiler toolchain
you use.  Please join #perl6 to discuss you experiences.

=head1 ENVIRONMENT

PERL6EXE - if exported by the shell, specifies where to look for an
installed Perl 6 executable. Not required if your shell executes 'perl6'
anyway.  The setting is saved as 'Perl 6 executable' in config.proto.
It is configured automatically if you let proto install Rakudo (and
Parrot).  For example, to use perl6.pbc instead of the fakecutable use
something like:

    PERL6EXE=/my/parrot_install/bin/parrot \
        /my/parrot_install/lib/<version>/languages/perl6/perl6.pbc \
        ./proto

=head1 ROADMAP

The current proto roadmap is linked to the Rakudo * initiative and the
Synopsis 11 Modules proposal in
L<//github.com/rakudo/rakudo/blob/master/docs/S11-Modules-proposal.pod>.
TODO: rename the doc to S11-Modules-plan.pod, so that its URL does not
overflow perldoc's 72 character line preference.

The Rakudo * release needs only a subset of these proto roadmap goals.
The rest are desirable enhancements.

The previous proto roadmap was called C<installed-modules>, and is
included below for reference, but not necessarily to be implemented.

=head2 Bootstrap

Simplify the initial download to only the F<proto.pl> file, which can
run in any temporary directory.  Use the Perl 5 L<LWP::UserAgent> and
L<Archive::Extract> to download and process the Parrot and Rakudo
release archive files.

Use a setting in proto.conf to control whether to remove the source code
trees after a successful installation (the default will be to remove).

=head2 Platforms

Run in more than just Unix compatible environments.  So far, proto has
conque^Wbeen used in Linux and OS X.  In particilar, it should embrace
Microsoft Windows.  To be Windows compatible, proto uses Perl 5 modules
such as File::Spec to handle all directory and file names. [mostly done]

=head2 Directories

The user may override all directories.  The default base is .perl6 in
the user's home directory, which proto.conf will call 'Perl 6 base'.
That is ~/.perl6 or $HOME/.perl6 in Unix compatible systems, or
%HOMEDRIVE%%HOMEPATH%\.perl6 in Windows. Subdirectories in .perl6 are:

    git                 for fetching Rakudo if needed
    lib                 start of the Perl 6 module hierarchy
    parrot              main Parrot download/build directory
        parrot-x.y.z    source directory of a specific Parrot version
    parrot_install      parrot virtual machine runtime base
        bin             for parrot executables, eg perl6.pbc
    proto               keep proto.conf and projects.state here
        cache           where projects are downloaded and tested
    rakudo              Rakudo download/build directory
        rakudo-yyyy.mm  source directory of a specific Rakudo version
    svn                 for fetching Parrot if needed

By making the parrot, parrot_install and rakudo directories not nest in
each other, there is more flexibility for customization.  If a user
wants the directory nesting done by Rakudo's --gen-parrot option, she
can edit proto.conf to use that, or any other layout.

TODO: plan a system wide parrot_install (root privileges required).
Correctly handle system wide *.pm,, *.pir and *.pbc files in
F<parrot_install/lib/2.3.0-devel/languages/perl6/lib> when Parrot 2.4.0
comes out.  (BTW, since 2.3.0 is a "supported" release, why the -devel?)

TODO: install symlinks in a Unix PATH directory (root required) for
system wide commands such as 'perl6', 'rakudo' and 'proto'.  Windows
has no symlinks, so try batch files, F<*.lnk> files etc.  If that all
fails, designate preferably just one new F<bin> directory to contain
perl6.exe, parrot.exe etc. and add that to the Windows PATH.

=head2 Runtimes

The F<.perl6> base directory makes it easier to install multiple Perl 6
implementations side by side.  Eventually there may be Rakudo on Parrot,
Rakudo on Common Language Infrastructure, Pugs, Mildew and others.

Proto has special project references for proto and each runtime, so that
they can also be installed, updated or uninstalled.  The command
C<perl6> could mean any one of C<rakudo>, C<pugs> and so on.

As a start, proto could automate the checking out and compiling of
Rakudo's alpha branch alongside master.

=head2 Commands

The C<proto> file, a Perl 5 program, has so far kept a very low profile.
In future, C<proto> will intercept and run the following commands.
Proto will pass everything else through to the Perl 6 F<Installer.pm>:

    help            # display commands and their arguments
    configure       # create proto.conf if it does not exist
    make commands   # add 'proto', 'rakudo' and 'perl6' into your path
    reconfigure     # interactively change an existing proto.conf
    upgrade proto   # download proto's files if newer ones are available
    selftest        # check the proto installation using mock drivers
    install rakudo  # according to proto.conf (only if not installed)
    upgrade rakudo  # change installed Rakudo version
    test rakudo     # uses the spectest suite to thoroughly check Rakudo

Proto used to carry the first two of these actions out silently.  To
give the user more direct control in future, the user must explicitly
issue each command.  If the use gives no command, proto displays help.

=head2 Modules

The Rakudo * plan to implement module versioning is a subset of the S11
modules spec.  Proto must download and install a specific version of a
module to satisfy dependencies.  The proto granularity of downloading
must change from 'project' to 'module'.  Installing a project that
contains multiple modules will need more redesign, and probably changes
to F<projects.list>.  Authors will continue to manage their repositories
as projects.  Proto will download individual files using the Perl 5
L<LWP::UserAgent>, or a Rakudo based replacement when this becomes
available.

What is the simplest thing that could possibly work?

All published modules must declare a "full name" (with :auth and :ver).
Add a 'modules.list' with these possible layouts:

    Module:auth<name>:ver<number>:                                or
    Namespace::and::Module:auth<name>:ver<number>:
        url: http://www.zzz.com/path/to/a/versioned/module.pm     or
        project: http://www.zzz.com/path/to/a/versioned/module.pm

TODO: implementation design!

=head2 Testing

Easier said than done, but there needs to be a start.  The command
C<proto selftest> should provide some mock drivers and files, using
these to cover and test as much of proto's functionality as possible.

Remember L<http://use.perl.org/~masak/journal/39583> and implement it.

=head2 Releases

The default for a novice user will be to download the
most recent stable tarballs for Rakudo and Parrot.  Proto can do
that using only core modules, and without requiring installation
of subversion or git software.  It does mean that proto needs to be
updated with new default version numbers as soon as possible after
each Rakudo release.  Rakudo developers can change to downloading
the latest Rakudo and Parrot versions by editing proto.conf.

=head2 Authoring

Convert the 'create-new-project' script into a C<proto newmodule>
command that helps the developer follow Well Though Out Practices.
Consider "Modules: Creation, Use, and Abuse" in the Perl 5 L<perlmodlib>
when doing the design.  Implement it as a separate Proto module.

=head2 Refactoring

Whilst proto was being revised to work with the current NQP-RX based
Rakudo, problems were handled by working around them, commenting the
fixes as WORKAROUND, and reporting them in #perl6.
This approach leaves a TODO item here, to find WORKAROUND comments,
handle them better, or notify http://rt.perl.org/rt3 by mailing
rakudobug@perl.org.

=head2 Rename

Renaming the proto project is a good subject for a bikeshed discussion.
Proto has achieved its goal of helping to install stuff.  It has also
contributed in part to a successor in the form of Plumage, see
L<http://gitorious.org/parrot-plumage>.  A name change would imply new
ambitions, which the proto contributors currently do not have.

If the Rakudo * distrubution opts to bundle a subset of the proto files,
as now seems likely, it might be fitting to rename just the C<proto>
command.  For example, C<rakudo-install>.  Let the discussions begin...

=head1 CPAN

Proto, as (merely) a prototype installer, can explore how any Perl 6
software relates to CPAN, which is a Perl 5 oriented network.  Some
aspects to examine are whether or how CPAN processes Perl 6 files,
alternative systems to CPAN, and publishing Proto in CPAN.

=head2 Perl 6 software on CPAN

CPAN has over 100 modules in the Perl6:: namespace.  They all emulate
parts of the Perl 6 language using Perl 5.  

People disagree about whether all software in CPAN should be Perl 5
compatible, as they do about whether Perl 6 is actually Perl.  The proto
developers feel that Perl 6 is definitely Perl, and that Perl 6 software
should be distributed via CPAN.  Discussion with CPAN maintainers
(search the IRC logs) shows that if we suggest how CPAN can distribute
Perl 6 content, they are willing to adapt their end.  See:

 http://www.nntp.perl.org/group/perl.cpan.workers/2010/01/msg639.html
 http://www.nntp.perl.org/group/perl.cpan.workers/2010/04/msg819.html

But CPAN should be changed as little as possible, to reduce possible
problems for the existing Perl 5 content.

=head2 Alternatives to CPAN

Perl 6 developers have used mainly Git and Subversion for software
distribution, They found that the CPAN standards and processes are Perl
5 centric and difficult to use for Perl 6 software.  Proto uses mainly
Git and also supports Subversion, but not yet CPAN.

Other designs (references please) such as sixpan and cpan6 have also
tackled the question of how to distribute Perl 6 (and other) content.
Proto has yet to explore possible links to them.

http://blogs.perl.org/users/brian_d_foy/2010/04/what-could-a-completely-different-cpan-client-do.html

=head2 Proto as a CPAN module

Another move being considered is to publish proto as a Perl 5 module to
be called something like P6::Proto::Installer. Or Perl6::something.
Or something else.  Comments are being actively sought.

=head1 Proto status summary (2010-04-08 for jnthn)

I see proto as an essential part of the Rakudo * distribution.  Thus it will need a more fitting name.

Newly added:

1. Rakudo/ng migration done, should still be Rakudo/alpha compatible.

2. Building on Windows 32 bit mostly works (Strawberry and ActiveState, MinGW and MSVC++), 64 bit not yet.

3. Self bootstrapping from a single Perl 5 script works (without Git or Subversion).

4. Defaults all builds, executables and libraries in the $HOME/.perl6 directory hierarchy (overrideable).

Missing / currently working on:

1. "install" a project works.  "test", "update" and "uninstall" are broken.

2. Adding "proto", "rakudo" and "perl6" commands to your PATH.

3. Distributing proto as a CPAN module.

4. Installing multiple Perl 6 implementations side by side, starting with Rakudo/alpha

Planning for Rakudo *

1. Keep multiple versions of modules side by side (S11-Versioning).

2. Help the user easily install Git and Subversion.

3. 64 bit support on Windows.

After Rakudo *:


1. Distribute Perl 6 modules via CPAN (up- and down-loads).

=head1 TODO

1.  The new Rakudo master is not backwards compatible with the alpha
    branch, so rip out the old legacy project support.  [done, easy]

2.  For Windows compatibility, change all hard coded mkdir and cp
    commands to use the Perl 5's L<ExtUtils::Command> with C<-e mkpath>
    and C<-e cp> instead.  [mostly done]

3.  The install command will need to be able specify :auth<> and :ver<>
    and look them up in projects.list.

4.  Advise the user to either 1) point the system path to
    installed_modules/bin, or 2) add a symbolic link in a system path
    directory to the perl6 fakecutable.

5.  Also put the proto executable in the bin directory and enable it to
    run independent of the current working directory.

99. Reduce all WORKAROUND comments to simple cases in rakudobug reports
    and replace the comments with TODO items linked to RT numbers.

=head1 Rakudo/alpha old TODO list (partly deprecated)

The installed-modules branch plans to improve proto by doing the
following:

1.  Place all installed Perl 6 modules (.pm and .pir files) into one
    folder hierarchy. Rakudo now preloads @*INC with $HOME/.perl6lib,
    followed by <parrot_install>/lib/<version/languages/perl6/lib, the
    directories in PERL6LIB, and lastly '.' (the current directory).
    Add a "Perl 6 library" setting to config.proto, with
    $HOME/.perl6/lib as default value.
    [DONE]

2.  Keep a separate cache directory per project for all processing
    prior to installation. Allow the cache directory to be cleaned or
    removed without affecting the installed module.
    Add a "Proto cache directory" to config.proto with a default value
    of <proto_base>/cache.  [DONE]

3.  Add a projects.state file to register installed projects.
    The format of projects.state is similar to projects.list, currently
    with a C<state> field whose value may be 'legacy', 'built', 'tested'
    (meaning passed *all* tests in the cache directory) or 'installed'.
    Route all access to projects.state information via the Ecosystem
    class.  [DONE]

4.  Rename the existing "fetch" submethod to "download", "install" ->
    "fetch", "update" -> "refresh" and "uninstall" -> "clean".
    Rename Ecosystem::is-installed() to Ecosystem::is_fetched(). [DONE]

5.  Factor out the code common in the existing "install" and "update"
    methods, or unify them and add a new/existing flag. Either way,
    stop the repetition because we need to edit this part
    significantly.  [DONE]

6.  Replace the 'Parrot directory' and 'Rakudo directory' settings with
    'Perl 6 executable' in config.proto.  [DONE]

7.  Make install_perl6 implement
    L<http://www.rakudo.org/how-to-get-rakudo>, including the new
    'make install' step.  [DONE]

8.  Use the shiny new %*ENV for passing environment variables to child
    processes.
    [DONE]

9.  Add a new "install" step to the end of the existing "fetch,
    configure, build, test" workflow, to copy module files to the
    "Perl 6 library" tree.
    To install modules into the global library tree, first look for an
    an 'install' target in the Makefile, run it if found.
    If there is no 'install', check that all the files in lib/ can be
    copied without clobbering, then either proceed to copy or abort.
    [DONE]

10. Drop the migration plan for existing installations: laziness++ ;)
    Just warn the user as long as the old config.proto has not been
    upgraded, and record as "state: legacy: /path" in projects.state.
    This must be overwritten if the user later re-installs the project.
    [DONE]

11. Add a showstate command to report on the state of all fetched or
    installed projects.
    [DONE]

12. Handle "uninstall" by Makefile or by listing all the names in
    $project/lib and deleting each same named file in "Perl 6 library".
    Also remove the project name from projects.installed and delete the
    project cache directory. Think "realclean".
    We could keep the cache, but a "rm -rf" and a new fetch is cleaner.
    [PARTDONE]

13. Add a new "update" command. To be fail-safe, cache the project's
    downloaded cache (yes, cache the cache) by copying everything into
    another directory called cache/$project.temp. Refresh the normal
    cache. Determine whether there are any differences and back out
    politely if nothing changed. Build and test the updated project in
    the refreshed cache directory. If it passes, rename the cache
    directory to cache/$project.new and rename the cache/$project.temp
    to just cache/$project, and uninstall the old version of the
    project.  Discard the old project cache and rename the .new back.
    Install.

14. Ensure robustness of the workflow, so that an error in fetching,
    building or testing any dependency, stops the dependent module
    being installed. Refactor the existing code to do this very
    concisely in the top level methods.

15. Validate @*INC by exiting with a friendly explanation if @*INC does
    not contain the 'Perl 6 library' directory. List the possible
    fixes: edit config.proto (set Perl 6 library), or any one of
    ~/.bash_profile, ~/.bash_login, or ~/.profile (set PERL6LIB).
    Make this behaviour optional with a 'Validate Perl 6 library'
    option in config.proto.

16. Update create-new-project to support install, update and uninstall
    in its Makefile. Document it as a guideline for module developers.
    This facility is new to proto, so it is also new to all projects.
    The 'make' utility will need to know where to find
    'Perl 6 library', so do this:

      %*ENV<PERL6LIB> = %!config-info{'Perl 6 library'}

17. When loading projects.list also load a projects.local if it exists.
    The projects.local file allows individual projects to be handled by
    proto without causing git conflicts on projects.list.

18. ...keep planning and doing...

19. Build a test suite for proto itself, with the possibility of
    partial testing offline. With acceptable test coverage, proto will
    be safer to develop and use until other infrastructure tools usurp
    it.  Use a test version of config.proto that points to test
    directories, so that the main installation is not affected.
    For even better testing, consider testing proto inside a chroot
    jail to prevent bugs from damaging things. Building the jail may be
    a bit complicated though, think it through first.
    [OPTIONAL]

20. Improve the usage message and provide help per command.

21. Make 'test' (of a project) show details of failures. Also add a
    'test all' suitable for "Cheese speleology".
    [OPTIONAL]

22. Refactor into MVC form. Details to be determined. Some ideas:
    Model is currently only Ecosystem (metadata). It should also
    include handling files and directories in the proto/cache/ and the
    'Perl 6 library' tree, perhaps within a separate module.
    View is the part of Installer.pm that deals with lists of projects,
    commands and other user I/O.
    Controller is the part of Installer.pm that er, controls flow, but
    it should leave the actual updating of projects, files and state to
    Model.
    [OPTIONAL]

23. Emulate Debian's 'popularity-contest' for package usage statistics,
    based on voluntary anonymous submission via smtp or http.
    [OPTIONAL]

=pod SEE ALSO

App::cpanminus Module::Build (make substitute)

=cut
