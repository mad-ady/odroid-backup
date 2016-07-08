#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
#use UI::Dialog; #loaded dynamically later
#use Number::Bytes::Human; #loaded dynamically later

my $dialog;
my %bin;
my %options = ();
my %dependencies = (
'sfdisk' => 'sudo apt-get install sfdisk',
'fsarchiver' => 'sudo apt-get install fsarchiver',
'udevadm' => 'sudo apt-get install udev',
'blockdev' => 'sudo apt-get install util-linux',
);

GetOptions(\%options, 'help|h', 'allDisks|a');
if(defined $options{help}){
    print "Odroid Backup program\n
Usage $0 options
Options

--help|-h       Print this message
--allDisks|-a   Display all disks in the selector (by default only removable disks are shown)

";
    exit 0;
}
checkDependencies();
checkUser();

my $mainOperation = $dialog->radiolist(title => "Odroid Backup", text => "Please select if you want to perform a backup or a restore:", 
                    list => [   'backup', [ 'Backup partitions', 1],
                                'restore', [ 'Restore partitions', 0] ]);
                                
print "$mainOperation\n";

if($mainOperation eq 'backup'){
    #get a list of removable drives (or all drives if so desired)
    my %disks = getRemovableDisks();
    
    #convert the disks hash to an array the way radiolist expects
    my @displayedDisks = ();
    foreach my $disk (sort keys %disks){
        push @displayedDisks, $disk;
        my @content =  ( "$disks{$disk}{model}, $disks{$disk}{sizeHuman}, $disks{$disk}{removable}", 0 );
        push @displayedDisks, \@content;
    }
    
#    print Dumper(\@displayedDisks);
    #create a radio dialog for the user to select the desired disk
    my $selectedDisk = $dialog->radiolist(title => "Odroid backup", text => "Please select the disk you wish to backup",
                    list => \@displayedDisks);
    
    print $selectedDisk;
}
if($mainOperation eq 'restore'){
    
}

sub getRemovableDisks{
    opendir(my $dh, "/sys/block/") || die "Can't opendir /sys/block: $!";
    my %disks=();
    my $human = Number::Bytes::Human->new(bs => 1024, si => 1);
    while (readdir $dh) {
        my $block = $_;
        next if ($block eq '.' || $block eq '..');
        print "/sys/block/$block\n";
        my @info = `$bin{udevadm} info -a --path=/sys/block/$block`;
        my $removable = 0;
        my $model = "";
        foreach my $line (@info){
            if($line=~/ATTRS\{model\}==\"(.*)\"/){
                $model = $1;
                $model=~s/^\s+|\s+$//g;
            }
            if($line=~/ATTR\{removable\}==\"(.*)\"/){
                $removable = $1;
                $removable = ($removable == 1)?"removable":"non-removable";
            }
        }
        if(defined $options{'allDisks'} || $removable eq 'removable'){
            my $size = getDiskSize($block);
            $disks{$block}{sizeHuman} = $human->format($size);
            $disks{$block}{size} = $size;
            $disks{$block}{model} = $model;
            $disks{$block}{removable} = $removable;
            
        }
        print "$block\t$model\t$removable\n";
    }
    return %disks;
    
}

sub getDiskSize{
    my $disk = shift;
    my $size = `$bin{blockdev} --getsize64 /dev/$disk`;
    return $size;
}

sub checkUser{
    if($< != 0){
        #needs to run as root
        $dialog->msgbox(title => "Odroid Backup error", text => "You need to run this program as root");
        exit 2;
    }
}

sub checkDependencies{
    #check for sfdisk, partimage, fsarchiver and perl modules
    
    my $message = "";
    
    #check if UI::Dialog is available...
    my $rc = eval{
        require UI::Dialog;
        1;
    };

    if($rc){
        # UI::Dialog loaded and imported successfully
        # initialize it and display errors via UI
        $dialog = new UI::Dialog ( backtitle => "Odroid Backup", debug => 0, width => 400, order => [ 'zenity', 'dialog', 'ascii' ], literal => 1 );
        
    }
    else{
        $message .= "UI::Dialog missing - You can install it with sudo apt-get install libui-dialog-perl zenity dialog\n";
    }
    
    #check if other perl modules are available
    my $readable = eval{
        require Number::Bytes::Human;
        1;
    };
    
    if(!$readable){
        $message .= "Number::Bytes::Human missing - You can install it with sudo apt-get install libnumber-bytes-human-perl\n";
    }
    
    #check if system binaries are available
    foreach my $program (sort keys %dependencies){
        $bin{$program} = `which $program`;
        $bin{$program}=~s/\s+|\r|\n//g;
        if($bin{$program} eq ''){
            $message .= "$program missing - You can install it with $dependencies{$program}\n";
        }
    }
    
    #complain if needed
    if($message ne ''){
        $message = "Odroid Backup needs the following packages to function:\n\n$message";
        
        if($rc){
            $dialog->msgbox(title => "Odroid Backup error", text => $message);
        }
        else{
            print $message;
        }
        exit 1;
    }
}
