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
'blkid' => 'sudo apt-get install util-linux',
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

my $human = Number::Bytes::Human->new(bs => 1024, si => 1);

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
    
    if($selectedDisk){
        #get a list of partitions from the disk and their type
        my %partitions = getPartitions($selectedDisk);
        print Dumper(\%partitions);
        
        #convert the partitions hash to an array the way checklist expects
        my @displayedPartitions = ();
        foreach my $part (sort keys %partitions){
            push @displayedPartitions, $part;
            my $description = "";
            if(defined $partitions{$part}{label}){
                $description.="$partitions{$part}{label}, ";
            }
            $description.="$partitions{$part}{sizeHuman}, ";
            
            if(defined $partitions{$part}{literalType}){
                $description.="$partitions{$part}{literalType} ($partitions{$part}{type}), ";
            }
            else{
                $description.="type $partitions{$part}{type}, ";
            }
            
            if(defined $partitions{$part}{mounted}){
                $description.="mounted on $partitions{$part}{mounted}, ";
            }
            
            if(defined $partitions{$part}{uuid}){
                $description.="UUID $partitions{$part}{uuid}, ";
            }
            
            $description.="start sector $partitions{$part}{start}";
            my @content =  ( $description, 0 );
            push @displayedPartitions, \@content;
        }
        
        #create a checkbox selector that allows users to select what they want to backup
        my @selectedPartitions = $dialog->checklist(text => "Please select the partitions you want to back-up",
                    list => \@displayedPartitions);
        print join(",", @selectedPartitions);
        
        if(scalar(@selectedPartitions)){
            #select a destination directory to dump to
            
            my $status = "";
            foreach my $partition (@selectedPartitions){
                if($partition eq 'mbr'){
                    #we use sfdisk to dump mbr
                }
                elsif($partition eq 'bootloader'){
                    #we use dd to dump bootloader
                    
                }
                else{
                    #regular partition. Based on the filesystem we dump it either with fsarchiver or partimage
                }
                
            }
        }
        else{
            $dialog->msgbox(title => "Odroid Backup error", text => "No partitions selected for backup. Program will close");
        }
        
    }
    else{
            $dialog->msgbox(title => "Odroid Backup error", text => "No disks selected for backup. Program will close");
    }
}
if($mainOperation eq 'restore'){
    
}

sub getPartitions{
    #get a list of partitions of a specified disk
    my $disk = shift;
    my $jsonData = `$bin{sfdisk} -l -J /dev/$disk`;
    print Dumper($jsonData);
    
    my %partitions = ();
    
    my %mounted = getMountedPartitions();
    
    if($jsonData){
        my $json = JSON->new->allow_nonref;
        my $sfdisk = $json->decode($jsonData);
        print Dumper($sfdisk);
        
        if(defined $sfdisk->{partitiontable}{partitions}){
            #add the MBR + EBR entry
            $partitions{'mbr'}{'start'} = 0;
            $partitions{'mbr'}{'type'} = 0;
            $partitions{'mbr'}{'size'} = 512;
            $partitions{'mbr'}{'sizeHuman'} = 512;
            $partitions{'mbr'}{'label'} = "MBR+EBR";
            
            #we need to find out where the first partition starts
            my $minOffset = 999_999_999_999;
            
            #list partitions from sfdisk + get their type
            foreach my $part (@{$sfdisk->{partitiontable}{partitions}}){
                $partitions{$part->{node}}{'start'} = $part->{start};
                $partitions{$part->{node}}{'type'} = $part->{type};
                my $size = getDiskSize($part->{node});
                $partitions{$part->{node}}{'size'} = $size;
                $partitions{$part->{node}}{'sizeHuman'} = $human->format($size);
                #also get UUID and maybe label from blkid
                my $output = `$bin{blkid} $part->{node}`;
                if($output=~/\s+UUID=\"([^\"]+)\"/){
                    $partitions{$part->{node}}{'uuid'} = $1;
                }
                if($output=~/\s+LABEL=\"([^\"]+)\"/){
                    $partitions{$part->{node}}{'label'} = $1;
                }
                if($output=~/\s+TYPE=\"([^\"]+)\"/){
                    $partitions{$part->{node}}{'literalType'} = $1;
                }
                
                #find out if the filesystem is mounted from /proc/mounts
                if(defined $mounted{$part->{node}}){
                    $partitions{$part->{node}}{'mounted'} = $mounted{$part->{node}};
                }
                
                $minOffset = $part->{start} if($minOffset > $part->{start});
            }
            
            #add the bootloader entry - starting from MBR up to the first partition start offset
            #We assume a sector size of 512 bytes - possible source of bugs
            $partitions{'bootloader'}{'start'} = 1;
            $partitions{'bootloader'}{'end'} = $minOffset;
            $partitions{'bootloader'}{'type'} = 0;
            $partitions{'bootloader'}{'size'} = ($minOffset - 1)*512;
            $partitions{'bootloader'}{'sizeHuman'} = $human->format($partitions{'bootloader'}{'size'});
            $partitions{'bootloader'}{'label'} = "Bootloader";
            
        }
        else{
            #no partitions on device?
            $partitions{"error"}{'label'} = "Error - did not find any partitions on device!";
        }
    }
    else{
        #error running sfdisk
        $partitions{"error"}{'label'} = "Error running sfdisk. No medium?";
    }
    return %partitions;
}

sub getMountedPartitions{
    open MOUNTS, "/proc/mounts" or die "Unable to open /proc/mounts. $!";
    my %filesystems = ();
    while(<MOUNTS>){
        if(/^(\/dev\/[^\s]+)\s+([^\s]+)\s+/){
            $filesystems{$1}=$2;
        }
    }
    close MOUNTS;
    return %filesystems;
}

sub getRemovableDisks{
    opendir(my $dh, "/sys/block/") || die "Can't opendir /sys/block: $!";
    my %disks=();
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
    $disk = "/dev/$disk" if($disk !~ /^\/dev\//);
    print Dumper(\$disk);
    my $size = `$bin{blockdev} --getsize64 $disk`;
    $size=~s/\r|\n//g;
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
    
    my $json = eval{
        require JSON;
        1;
    };
    if(!$json){
        $message .= "JSON missing - You can install it with sudo apt-get install libjson-perl\n";
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
