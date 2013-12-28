#!/usr/bin/perl

use strict;
use warnings;
use POSIX;
use Cwd;

sub DATETIME { strftime("%d/%m/%Y %H:%M:%S", localtime);}

my $name;
my $val;
my %properties;
my @acr_servers;
my $configfilepath;

# Read configuration parameters from conf file
if (open CONFIG, '<', 'acr_converter.conf') {
  $configfilepath = cwd() . '/acr_converter.conf';
}elsif (open CONFIG, '<', '~/acr_converter.conf') {
  $configfilepath = '~/acr_converter.conf';
}elsif (open CONFIG, '<', '/etc/acr_converter.conf') {
  $configfilepath = '/etc/acr_converter.conf';
}else { 
die DATETIME, " Failed to open config file acr_converter.conf from /etc or from ~/ or from pwd: $!\n";
}

my $config_linenum = 0;
my $config_section = "NONE";
my $is_global_configured = 0;
my $num_acr_servers = 0;

# Read the config file
while (<CONFIG>)
  {
  $config_linenum++;
unless ( m/^\s*#.*$/ or m/^\s*$/)
   {
   # Branch states of config file processing and set parameter variables accordingly
   # Reading outside of any sections
    if($config_section eq "NONE")
    {
      if (!$is_global_configured)
      {
	m/^\s*\[Global\]\s*$/ or die  DATETIME, " Error in config file $configfilepath. Config does not start with a [Global] section at line number: $config_linenum\n";
	$config_section = "GLOBAL";
      } else {
	m/^\s*\[ACR_server\]\s*$/ or die  DATETIME, " Error in config file $configfilepath. Expecting [ACR_server] or end of file: the [Global] section must be followed by zero or more [ACR_Server] sections at line number: $config_linenum\n";
	$config_section = "ACR_SERVER";
	$num_acr_servers++;
      }
    # Reading Global section
    } elsif ($config_section eq "GLOBAL") {
      if (m/\s*\w+\s*=\s*.+\s*/)
      {
	($name,$val)=m/\s*(\w+)\s*=\s*(.+)\s*$/;
	$properties{$name}=$val;
      } elsif (m/^\s*\[END Global\]\s*$/) {
	$is_global_configured = 1;
	$config_section = "NONE";
      } else {
	die DATETIME, " Invalid config file entry in $configfilepath at line number: $config_linenum\n";
      }
    # Reading ACR_SERVER section
    } elsif ($config_section eq "ACR_SERVER") {
      if (m/\s*\w+\s*=\s*.+\s*/)
      {
	($name,$val)=m/\s*(\w+)\s*=\s*(.+)\s*$/;
	$acr_servers[$num_acr_servers]{$name}=$val;
      } elsif (m/^\s*\[END ACR_server\]\s*$/) {
	$config_section = "NONE";
      } else {
	die DATETIME, " Invalid config file entry in $configfilepath at line number: $config_linenum\n";
      }
    }
   }
  }
close(CONFIG);

# Cross-check validity of config file contents
$config_section eq "NONE" or die DATETIME, " Error in config file $configfilepath. Unterminated section at the end of file.\n";
if ($num_acr_servers == 0)
{
  print DATETIME, " No ACR servers configured in $configfilepath: Exiting cleanly\n";
  exit 0;
}

# Check required General parameters
foreach my $key ("SCP_script_temp_file", "SCP_download_temp_target_dir", "SSH_script_temp_file", "output_filename_tag", "segmentation_tag", "segmentation_script_temp_file", "output_directory", "slpitter_binary", "encoder_parameters", "debug", "SSH_binary", "SCP_binary", "BASH_binary", "RM_binary", "encoder_binary", "logfile")
{
  $properties{$key} or die DATETIME, " Error: Required global parameter \"$key\" is not defined in config file $configfilepath.\n";
}

# Check required ACR server parameters
foreach my $key ("ACR_server", "ACR_user", "ACR_calls_directory_root", "ACR_call_download_window_minutes")
{
  for(my $i=1; $i<=$num_acr_servers;$i++)
  {
    $acr_servers[$i]{$key} or die DATETIME, " Error: Required ACR server parameter: \"$key\" is not defined in config file $configfilepath in [ACR_server] section #$i.\n";
  }
}

die DATETIME, " Error: parameter \"debug\" holds a value of \"$properties{'debug'}\" in config file $configfilepath in section Global. Its valid values are \"true\" and \"false\"\n" unless $properties{'debug'} eq "true" || $properties{'debug'} eq "false";


select STDERR; $| = 1;  # make unbuffered
select STDOUT; $| = 1;  # make unbuffered

# Save outputs
*OLD_STDOUT = *STDOUT;
*OLD_STDERR = *STDERR;

# Redirect outputs to log file
open my $log_fh, '>>', "$properties{'logfile'}" or die DATETIME, " Falied to open logfile \"$properties{'logfile'}\" for appending: $!";
*STDOUT = $log_fh;
*STDERR = $log_fh;

select $log_fh; $| = 1;  # make unbuffered

print DATETIME, " Conversion utility started, config read from $configfilepath: contains $num_acr_servers ACR servers.\n";

my $current_acr_server;

#Loop through ACR servers
for($current_acr_server = 1; $current_acr_server<=$num_acr_servers; $current_acr_server++)
{
  print DATETIME, " Start processing ACR server #$current_acr_server: \"$acr_servers[$current_acr_server]{'ACR_server'}\".\n";

  # Create a shell script file to get list of modified files from ACR
  open REMOTE_SCRIPT, '>' , $properties{'SSH_script_temp_file'} or die DATETIME, " Failed to create shell script file to get list of modified files from ACR : $!\n";

  # Write commands into the shell script file to get list of modified files from ACR
  print REMOTE_SCRIPT "cd $acr_servers[$current_acr_server]{'ACR_calls_directory_root'}\n";
  print REMOTE_SCRIPT "find . -name \"*.xml\" -type f -mmin -$acr_servers[$current_acr_server]{'ACR_call_download_window_minutes'}\n";

  close REMOTE_SCRIPT;

  # Execute the script remotely to detect modified voice files
  open SSH_OUTPUT, "$properties{'SSH_binary'} -T $acr_servers[$current_acr_server]{'ACR_user'}\@$acr_servers[$current_acr_server]{'ACR_server'} <$properties{'SSH_script_temp_file'} |" or die DATETIME , " Failed to execute the script remotely to detect modified voice files: $!\n";

  my @files_to_download;

  # Create a file that will hold scp download commands
  open SCP_TEMP_FILE, '>' , $properties{'SCP_script_temp_file'} or die DATETIME, " Failed to create a file that will hold scp download commands: $!\n";

  while (<SSH_OUTPUT>)
  {
    chomp;

    # Put XML file name in downloader shell script
    s/.\/(.*)/$1/;
    print SCP_TEMP_FILE "$properties{'SCP_binary'} $acr_servers[$current_acr_server]{'ACR_user'}\@$acr_servers[$current_acr_server]{'ACR_server'}:$acr_servers[$current_acr_server]{'ACR_calls_directory_root'}$_ $properties{'SCP_download_temp_target_dir'}\n";

    # Store XML file name for tag extraction
    push @files_to_download, $_;
    
    # Put WAV file name in downloader shell script
    s/(.*)\.xml$/$1.wav/;
    print SCP_TEMP_FILE "$properties{'SCP_binary'} $acr_servers[$current_acr_server]{'ACR_user'}\@$acr_servers[$current_acr_server]{'ACR_server'}:$acr_servers[$current_acr_server]{'ACR_calls_directory_root'}$_ $properties{'SCP_download_temp_target_dir'}\n";
  }

  my $scp_script_size = tell SCP_TEMP_FILE;

  # Close files and remove temp file for SSH
  close SSH_OUTPUT;
  close SCP_TEMP_FILE;
  unlink($properties{'SSH_script_temp_file'}) == 1 or warn DATETIME, " Failed to remove temp file for SSH: $!\n";

  if ($scp_script_size >0)
  {
    # Download the voice files for conversion by executing the download shell script prepared previously
    if ($properties{'debug'} eq "true")
    {
      system("$properties{'BASH_binary'} $properties{'SCP_script_temp_file'} >>$properties{'logfile'} 2>>$properties{'logfile'}") == 0 or die DATETIME, " Failed to download the voice files for conversion by executing the download shell script prepared previously: $!\n";
    }else{
      system("$properties{'BASH_binary'} $properties{'SCP_script_temp_file'} >/dev/null 2>/dev/null") == 0 or die DATETIME, " Failed to download the voice files for conversion by executing the download shell script prepared previously: $!\n";
    }

    # Remove the downloader shell script file
    unlink($properties{'SCP_script_temp_file'}) == 1 or warn DATETIME, " Failed to remove the downloader shell script file: $!\n";

    # Create the temp shell script file for segmentation
    open SEGMENTATION_TEMP_SCRIPT_FILE, '>' , $properties{'segmentation_script_temp_file'} or die DATETIME,  " Failed to create the temp shell script file for segmentation: $!\n";
    print SEGMENTATION_TEMP_SCRIPT_FILE "#!$properties{'BASH_binary'}\ncd $properties{'output_directory'}\n";

    my $wav_file_to_convert;
    my $xml_filename;
    my $fallback_output_filename;
    my $nr_of_files_to_split = 0;

    # Loop through each xml file downloaded
    foreach (@files_to_download)
    {
	# Create the correct path of the XML file where scp downloaded it
	s/^.*\/(\w*.xml)/$properties{'SCP_download_temp_target_dir'}$1/;

	# Create the correct path of the WAV file where scp downloaded it for potential conversion later
	$xml_filename = $wav_file_to_convert = $fallback_output_filename = $_;
	$wav_file_to_convert =~ s/^(.*).xml$/$1.wav/;
	$fallback_output_filename =~ s/^(.*).xml$/$1$properties{'output_filename_extension'}/;

	open XMLFILE, $_ or die DATETIME, " Failed to open xml file \"$_\" downloaded previously with scp: $!\n";

	my $file_needs_conversion = 0;
	my $segmentation_rule = "";
	my $output_filename = "";
	
	# Parse the XML file to see if the recording is closed and to extract splitting parameters
	while (<XMLFILE>)
	{
	  chomp;
	  # File is eligible for conversion if the <noend> tag holds a "false" value
	  /<noend>false<\/noend>/ and $file_needs_conversion = 1;

	  # Find the segmentation tag and extract segmentation rules
	  if (/<$properties{'segmentation_tag'}>(.*?)<\/$properties{'segmentation_tag'}>/)
	  {
	    s/.*<$properties{'segmentation_tag'}>(.*?)<\/$properties{'segmentation_tag'}>/$1/;
	    s/,/ /g;
	    $segmentation_rule = $_;
	  }
	  
	  # Find the output filename tag and extract it
	  if (/<$properties{'output_filename_tag'}>(.*?)<\/$properties{'output_filename_tag'}>/)
	  {
	    s/.*<$properties{'output_filename_tag'}>(.*?)<\/$properties{'output_filename_tag'}>.*/$1/;
	    $output_filename = $_ . $properties{'output_filename_extension'};
	  }
	}
	close XMLFILE;
	
	if ($file_needs_conversion and $output_filename eq "")
	{
	  $output_filename = $fallback_output_filename;
	}
	
	$file_needs_conversion and print SEGMENTATION_TEMP_SCRIPT_FILE "$properties{'slpitter_binary'} $wav_file_to_convert $properties{'encoder_binary'} $output_filename \"$properties{'encoder_parameters'}\" $properties{'RM_binary'} $segmentation_rule\n" and $nr_of_files_to_split++;
	
	if ($properties{'debug'} eq "true")
	{
	  if ($file_needs_conversion)
	  {
	    print DATETIME, " Will invoke from conversion script: $properties{'slpitter_binary'} $wav_file_to_convert $properties{'encoder_binary'} $output_filename \"$properties{'encoder_parameters'}\" $properties{'RM_binary'} $segmentation_rule\n";
	  } else {
	    print DATETIME, " Voice file: $wav_file_to_convert still recording. No conversion performed.\n" unless $file_needs_conversion
	  }
	}
    }
    
    close SEGMENTATION_TEMP_SCRIPT_FILE;

    if ($nr_of_files_to_split > 0)
    {
      print DATETIME, " Number of files to convert/split for ACR server #$current_acr_server \"$acr_servers[$current_acr_server]{'ACR_server'}\" is: $nr_of_files_to_split.\n";

      # Perform file conversion and splitting
      if ($properties{'debug'} eq "true")
      {
	print DATETIME, " Invoking temp conversion script: \"$properties{'BASH_binary'} $properties{'segmentation_script_temp_file'}\"\n";
	system ("$properties{'BASH_binary'} $properties{'segmentation_script_temp_file'} >>$properties{'logfile'} 2>>$properties{'logfile'}") == 0 or die DATETIME, " Failed to perform file conversion and splitting: $!\n";
      }else{
	system ("$properties{'BASH_binary'} $properties{'segmentation_script_temp_file'} >>/dev/null 2>>/dev/null") == 0 or die DATETIME, " Failed to perform file conversion and splitting: $!\n";
      }

      # Remove temp segmentation and conversion script file
      unlink($properties{'segmentation_script_temp_file'}) == 1 or warn DATETIME, " Failed to remove temp segmentation and conversion script file: $!\n";

      # Remove downloaded voice and xml files

      system("$properties{'RM_binary'} -f $properties{'SCP_download_temp_target_dir'}/*.xml") == 0 or warn DATETIME, " Failed to remove downloaded xml files: $!\n";
      system("$properties{'RM_binary'} -f $properties{'SCP_download_temp_target_dir'}/*.wav") == 0 or warn DATETIME, " Failed to remove downloaded voice files: $!\n";

      print DATETIME, " Conversion/split done for ACR server #$current_acr_server: $acr_servers[$current_acr_server]{'ACR_server'}.\n";
    } else {
      # Remove temp segmentation and conversion script file
      unlink($properties{'segmentation_script_temp_file'}) == 1 or warn DATETIME, " Failed to remove empty temp segmentation and conversion script file: $!\n";

      print DATETIME, " No downloaded files need conversion for ACR server #$current_acr_server: \"$acr_servers[$current_acr_server]{'ACR_server'}\" - all in recording or errored.\n";
    }
  } else {
    print DATETIME, " No voice files match configured criteria: \"Last modified $acr_servers[$current_acr_server]{'ACR_call_download_window_minutes'} min(s) ago\" for ACR server #$current_acr_server: \"$acr_servers[$current_acr_server]{'ACR_server'}\".\n";
  }
}

print DATETIME, " Finished processing all $num_acr_servers configured ACR servers: Exiting cleanly\n";

# Restore original saved outputs
*STDOUT = *OLD_STDOUT;
*STDERR = *OLD_STDERR;
