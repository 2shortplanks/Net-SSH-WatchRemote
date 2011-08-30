use inc::Module::Install;

# Define metadata
name           'Net-SSH-RemoteWatch';
all_from       'lib/Net/SSH/RemoteWatch.pm';

requires       'Moose'            => 2.0202;
requires       'Config::Settings' => 0.02;
requires       'Data::UUID'       => 1.217;
requires       'Hash::Merge'      => 0.12;

license 'perl';
githubmeta;

WriteAll;
