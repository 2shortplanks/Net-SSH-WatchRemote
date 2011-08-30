package Net::SSH::RemoteWatch;

use Moose;
use IPC::Open2 qw(open2);

use warnings;
use File::Spec::Functions qw(:ALL);
use Data::Dumper;  # not just for debugging, don't remove!
use Data::UUID;

=head1 NAME

Net::SSH::RemoteWatch - remote edit files via ssh

=head1 SYNOPSIS

   Net::SSH::RemoteWatch->new(
     ssh_command_line_arguments => ["server.example.com"],
     path_to_mount => "/Volumes/server.example.com"
   )->watch;

=head1 DESCRIPTION

The idea behind this module is that you want to ssh onto a remote
server and run a command on that remote server to open a document in
your local GUI editor on your local box.

This module assumes that you've got the remote box mounted locally
somehow (over NFS, SAMBA, SSHFS, etc.)  It B<does not> mount this path
for you.  You need to work out how to do that yourself.

You probably want to have a look at the C<remotewatch> script that
ships with this script to see how you can use this module from the
command line.

=head1 Attributes

This module itself is a standard Moose module.  All attributes are
read only after construction time.

=item ssh_command_line_arguments

ArrayRef. The command line options you want to pass to the ssh command
to connect to the remote server.

This attribute is required.

=cut

has ssh_command_line_options => (
  is => 'ro',
  isa => 'ArrayRef[Str]',
  required => 1,
);

=item path_to_mount

Str. The path to where the remote file system is mounted on your
local file system.  For example, if "/etc/passwd" on the remote
machine was found at "/Volumes/server.example.com/etc/passwd" on
your local machine then this should be set
to "/Volumes/server.example.com".

This attribute is required.

=cut

has path_to_mount => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

=item mount_relative_to

Str. Defines what path on the remote file system is mounted on the
local mount point.

For example if your home directory on the local machine is "/home/mark"
and this is mounted locally as "/Volumes/server.example.com" then
C<mount_relative_to> should be set to "/home/mark".

By default this is set to "/", i.e. you are mounting the root directory
on the remote machine on the local mount point.

=cut

has mount_relative_to => (
  is => 'ro',
  isa => 'Str',
  default => "/",
);

=item script_commands

Hash of Array of Str.  Defines what script command should be executed (passing the
path as the only argument) for a given command if there isn't
a special process_command_whatever method defined for that command.

By default the "file" command (which is executed whenever the editor
command is used on a file and no other command option is passed) and
"dir" command (which is executed whenever the editor command is used
on a directory and no other command option is passed) are both set
to C<["open"]> (which, if you're using Mac OS X, caused directories to
be opened by the finder and other files to be opened with the default
editor for that file type)

This hash can be interrogated using the following methods:

=over

=item get_script_command($command)

=item supports_script_command($command)

=back

=cut

has 'commands' => (
    traits    => ['Hash'],
    is        => 'ro',
    isa       => 'HashRef[ArrayRef[Str]]',
    default   => sub { {
      file => ['open'],
    } },
    handles   => {
        get_script_command      => 'get',
        supports_script_command => 'exists',
    },
);

=item editor_command_name

Str. The name of the editor command script that you want to install
on the remote server.  This defaults to C<ec> (for "editor command",
but also for everyone who is used to typing "ec" for emacs client)

=cut

has editor_command_name => (
  is => 'ro',
  isa => "Str",
  default => 'ec',
);

=item custom_temp_dir

Str.  Custom directory on the remote machine that can be accessed across
the mount point.  Useful if your normal system temp directory is not
accessible via the mount point.

=cut

has custom_temp_dir => (
    is => 'ro',
    isa => "Str",
);

=item verbose

Bool.  Should we be verbose (print info to STDERR) or not?  Default false.

=cut

has verbose => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
);

=item uuid

A UUID that inserted into the script that we install.  Can be used to
double check that the script was installed correctly.  The script will
return this when executed with the "-u" option.

=cut

has uuid => (
  is => 'ro',
  isa => 'Str',  # we're not picky!
  lazy_build => 1,
);

sub _build_uuid {
  return Data::UUID->new->create_str;
}

=item base_script

Str. The text of the script to run on the remote server when we login.  You
probably don't want to override this - it's the meat of the module.

=cut

has base_script => ( is => 'ro', isa => "Str", default => <<'ENDOFPERL' );
#!/usr/bin/perl

use strict;

########################################################################
# pick a location for the watch log
########################################################################

use File::Temp qw(:POSIX);
my $watchfile = tmpnam();

########################################################################
# write out the new ec ("editor command") script
########################################################################

unless(-d "$ENV{HOME}/bin") {
  mkdir("$ENV{HOME}/bin")
    or die "Can't create ~/bin"
}

{
  use IO::File;
  my $sfh = IO::File->new("$ENV{HOME}/bin/__COMMAND_NAME__","w")
    or die "Can't write to ~/bin/__COMMAND_NAME__: $!";

  $sfh->autoflush(1);

  my $ec = <<'PERL';
#!/usr/bin/perl

use strict;
use warnings;
use File::Temp qw/ tempfile /;
use Getopt::Std;

# process command line arguments
my %opts;
getopt('c',\%opts);

# print out the UUID if we were asked to
if ($opts{'u'}) {
  print "__UUID__\n";
  exit;
}

# no arguments?  create a temp file from STDIN
unless (@ARGV) {
  my ($fh, $filename) = tempfile( undef, __TEMPDIR__);
  print $fh $_ while (<STDIN>);
  @ARGV = ($filename); 
}

use Cwd;
use File::Spec::Functions qw(rel2abs);

my $path = rel2abs(shift);
my $command = 
 ($opts{'c'}) ? $opts{'c'} :
 (-d $path)   ? "dir"      :
 (-f $path)   ? "file"     :
 "newfile";

open my $fh, ">>", __WATCHFILE__
  or die "Can't write to watch log!";
print $fh $command . "|" . $path, "\n"
  or die "Can't write to watch log!";
close $fh
  or die "Can't close watch log!";
PERL

  use Data::Dumper;
  local $Data::Dumper::Terse = 1;
  $ec =~ s/__WATCHFILE__/Dumper($watchfile)/e;
  $sfh->print($ec);
}

chmod 0755, "$ENV{HOME}/bin/__COMMAND_NAME__"
  or die "Can't chmod ~/bin/__COMMAND_NAME__";

########################################################################
# check that ~/bin is our path
########################################################################

# check did the right command get called when we executed it?
unless (`__COMMAND_NAME__ -c` eq "__UUID__") {
  if ($ENV{SHELL} =~ m!/bash$!) {
    open my $bashrc, ">>", "$ENV{HOME}/.bashrc"
       or die "Can't write to ~/.bashrc: $!";
    print { $bashrc } <<'ENDOFBASHRC';

# Added automatically by watchremote
export PATH="$HOME/bin:$PATH";

ENDOFBASHRC
  } else {
    print STDERR <<'ENDOFWARNING';
 WARNING: ~/bin is not in your path, and I don't know how to add it for
          your shell!
ENDOFWARNING
  }
}

########################################################################
# monitor the output
########################################################################

# force the file to exist
unless (-e $watchfile) {
  open my $outfh, ">", $watchfile
    or die "Can't open watchfile!";
  print $outfh "# Created\n"
    or die "Can't write to watchfile!";
  close $outfh
    or die "Can't close watchfile!";
}

# replace this big perl process with a simple tail process
exec("tail","-f","-n","0",$watchfile);
ENDOFPERL

=back

=head1 Methods

=over

=item watch

Connect to the remote server and watch for changes

=cut

sub watch {
  my $self = shift;

  # open a connection to the remote server
  my ($to_process, $from_process) = $self->ssh_to_remote_server;

  # send the script to it and close the writing filehandle
  print {$to_process} $self->compute_script
    or die "Couldn't print to the ssh filehandle: $!";
  close $to_process
    or die "Couldn't close writing to the ssh filehandle: $!";

  # now just keep reading from the reading filehandle and processing the commands
  while (<$from_process>) {
    print STDERR "Got command: $_" if $self->verbose;
    chomp;
    my ($command, $path) = split /\|/, $_, 2;
    $path = catfile($self->path_to_mount,$path);
    $self->process_command($command, $path);
  }  
}

=item process_command($command, $path)

Process the command from the remote server on the local path passed.

This implmentation checks to see if this module has a method
called process_command_$command and, if so, calls it passing the
$path as the only argument.

If there isn't such a method then it simply calls process_with_shell_command

=cut

sub process_command {
  my $self = shift;
  my $command = shift;
  my $path = shift;

  my $method = "process_command_$command";
  if ($self->can($method))
    { return $self->$method($path); }

  return $self->process_with_shell_command($command,$path);
}         

=item process_with_shell_command($command, $path)

Process this command with a shell command.

Throws exception if no shell command is defined, unless
the command is "dir" or "newfile" which causes this to
try the "file" command instead.

=cut

sub process_with_shell_command {
  my $self = shift;
  my $command = shift;
  my $path = shift;
  
  unless($self->supports_script_command($command)) {
    if ($command eq "newfile" || $command eq "dir")
      { return $self->process_with_shell_command("file", $path); }
    die "Unknown command "
  }

  system(@{ $self->get_script_command($command) }, $path);
}

=item compute_script

Work out the script we should run on the remote server when we connect to
it.  It's this script that contains most of the magic.

=cut

sub compute_script {
  my $self = shift;

  my $script = $self->base_script;

  # replace the editor command name
  my $editor_command_name = $self->editor_command_name;
  $script =~ s/__COMMAND_NAME__/$editor_command_name/ge;
  
  # use custom temp dir?
  my $tempdir = $self->custom_temp_dir;
  local $Data::Dumper::Terse = 1;
  $tempdir = defined $tempdir ? 'DIR => '.Dumper($tempdir) : "";
  $script =~ s/__TEMPDIR__/$tempdir/;

  # insert the uuid
  $script =~ s/__UUID__/$self->uuid/eg;
 
  return $script;
}

=item ssh_to_remote_server

ssh to the remote server.  Return a list of pipes (one pipe to
talk to the remote server, one to get data from the remote server)

=cut

sub ssh_to_remote_server {
  my $self = shift;

  my ($to_process, $from_process);
  my $pid = open2($from_process, $to_process, 'ssh', @{ $self->ssh_command_line_options }, 'perl');
  return ($to_process, $from_process);
}

no Moose;
1;