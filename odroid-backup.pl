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
'dd' => 'sudo apt-get install coreutils',
'partclone.vfat' => 'sudo apt-get install partclone',
'partclone.info' => 'sudo apt-get install partclone',
'partclone.restore' => 'sudo apt-get install partclone',
'partprobe' => 'sudo apt-get install parted',
);

my $logfile = '/var/log/odroid-backup.log';

GetOptions(\%options, 'help|h', 'allDisks|a', 'text|t');
if(defined $options{help}){
    print "Odroid Backup program\n
Usage $0 options
Options

--help|-h       Print this message
--allDisks|-a   Display all disks in the selector (by default only removable disks are shown)
--text|-t       Force rendering with dialog even if zenity is available

";
    exit 0;
}
checkDependencies();
checkUser();
firstTimeWarning();

my $human = Number::Bytes::Human->new(bs => 1024, si => 1);

my $mainOperation = $dialog->radiolist(title => "Odroid Backup - Please select if you want to perform a backup or a restore:", text => "Please select if you want to perform a backup or a restore:", 
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
    my $selectedDisk = $dialog->radiolist(title => "Odroid backup - Please select the disk you wish to backup", text => "Please select the disk you wish to backup",
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
            my @content =  ( $description, 1 );
            push @displayedPartitions, \@content;
        }
        
        #create a checkbox selector that allows users to select what they want to backup
        my @selectedPartitions = $dialog->checklist(title => "Odroid backup - Please select the partitions you want to back-up", text => "Please select the partitions you want to back-up",
                    list => \@displayedPartitions);
        print join(",", @selectedPartitions);
        
        if(scalar(@selectedPartitions) > 0 && $selectedPartitions[0] ne '0'){
            #select a destination directory to dump to
            my $directory = $dialog->dselect('path' => ".");
            print $directory;
            if($directory){
                #truncate log
                `echo "Starting backup process" > $logfile`;
                
                my $partitionCount = scalar(@selectedPartitions);
                my $progressStep = int(100/$partitionCount);
                
                foreach my $partition (reverse @selectedPartitions){
                    #log something
                    `echo "*** Starting to backup $partition ***" >> $logfile`;
                    
                    #if the backend supports it, display a simple progress bar
                    if($dialog->{'_ui_dialog'}->can('gauge_start')){
                        $dialog->{'_ui_dialog'}->gauge_start(title => "Odroid Backup", text => "Performing backup...", percentage => 1);
                    }
                    if($partition eq 'mbr'){
                        #we use sfdisk to dump mbr + ebr
                        `$bin{sfdisk} -d /dev/$selectedDisk > '$directory/partition_table.txt'; echo "Error code: $?" >> $logfile `;
                        `cat '$directory/partition_table.txt' >> $logfile 2>&1`;
                        if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                            $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                            #sleep 5;
                        }
                    }
                    elsif($partition eq 'bootloader'){
                        #we use dd to dump bootloader. We dump the partition table as a binary, just to be safe
                        `$bin{dd} if=/dev/$selectedDisk of="$directory/bootloader.bin" bs=512 count=$partitions{bootloader}{end} >> $logfile 2>&1; echo "Error code: $?" >> $logfile`;
                        my $size = -s "$directory/bootloader.bin";
                        `echo "*** Bootloader backup size: $size bytes ***" >> $logfile`;
                        if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                            $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                            #sleep 5;
                        }
                    }
                    else{
                        #regular partition. Based on the filesystem we dump it either with fsarchiver or partclone
                        $partition=~/([0-9]+)$/;
                        my $partitionNumber = $1;
                        
                        if($partitions{$partition}{literalType} eq 'vfat'){
                            #we use partclone
                            `$bin{'partclone.vfat'} -c -s $partition -o "$directory/partition_${partitionNumber}.img" >> $logfile 2>&1; echo "Error code: $?" >> $logfile`;
                            `$bin{'partclone.info'} -s "$directory/partition_${partitionNumber}.img" >> $logfile 2>&1`;
                            if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                                $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                #sleep 5;
                            }
                        }
                        elsif($partitions{$partition}{literalType} =~/ext[234]/){
                            #we use fsarchiver
                            `$bin{'fsarchiver'} savefs "$directory/partition_${partitionNumber}.fsa" $partition >> $logfile 2>&1; echo "Error code: $?" >> $logfile`;
                            `$bin{'fsarchiver'} archinfo "$directory/partition_${partitionNumber}.fsa" >> $logfile 2>&1`;
                            if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                                $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                #sleep 5;
                            }
                        }
                        else{
                            #not supported filesystem type!
                            $dialog->msgbox(title => "Odroid Backup error", text => "The partition $partition has a non-supported filesystem. Backup will skip it");
                            `echo "*** Skipping partition $partition because it has an unsupported type ($partitions{$partition}{literalType}) ***" >> $logfile`;
                            
                            if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                                $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                #sleep 5;
                            }
                        }
                    }
                }
                
                #finalize progress bar
                if($dialog->{'_ui_dialog'}->can('gauge_set')){
                    $dialog->{'_ui_dialog'}->gauge_set(100);
                    #sleep 5;
                }
                
                #show backup status
                $dialog->textbox(title => "Odroid Backup status", path => $logfile);
                #backup is finished. Program will now exist.
            }
            else{
                $dialog->msgbox(title => "Odroid Backup error", text => "No destination selected for backup. Program will close");
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
    #select source directory
    my $directory = $dialog->dselect(title => "Odroid backup - Please select the directory holding your backup", text => "Please select the directory holding your backup", 'path' => ".");
    print $directory;
    if($directory){
        #check that there are files we recognize and can restore
        opendir ( DIR, $directory ) || die "Error in opening dir $directory\n";
        my %partitions = ();
        while( (my $filename = readdir(DIR))){
            #print("$filename\n");
            if($filename eq 'partition_table.txt'){
                #found MBR
                $partitions{'mbr'}{'start'} = 0;
                $partitions{'mbr'}{'literalType'} = "bin";
                $partitions{'mbr'}{'size'} = 512;
                $partitions{'mbr'}{'sizeHuman'} = 512;
                $partitions{'mbr'}{'label'} = "MBR+EBR";
                $partitions{'mbr'}{'filename'} = "$directory/$filename";
            }
            if($filename eq 'bootloader.bin'){
                #found Bootloader
                $partitions{'bootloader'}{'start'} = 512;
                $partitions{'bootloader'}{'literalType'} = "bin";
                $partitions{'bootloader'}{'size'} = -s "$directory/$filename";
                $partitions{'bootloader'}{'sizeHuman'} = $human->format($partitions{'bootloader'}{'size'});
                $partitions{'bootloader'}{'label'} = "Bootloader";
                $partitions{'bootloader'}{'filename'} = "$directory/$filename";
            }
            if($filename=~/partition_([0-9]+)\.(img|fsa)/){
                my $partition_index = $1;
                my $type = $2;
                #based on the extension we'll extract information about the partition
                if($type eq 'img'){
                    my @output = `$bin{'partclone.info'} -s "$directory/$filename" 2>&1`;
                    print join("\n", @output);
                    foreach my $line(@output){
                        if($line=~/File system:\s+([^\s]+)/){
                            $partitions{$partition_index}{'literalType'} = $1;
                        }
                        if($line=~/Device size:\s+.*= ([0-9]+) Blocks/){
                            #TODO: We assume a block size of 512 bytes
                            my $size = $1;
                            $size *= 512;
                            $partitions{$partition_index}{'size'} = $size;
                            $partitions{$partition_index}{'sizeHuman'} = $human->format($size);
                            $partitions{$partition_index}{'label'} = "Partition $partition_index";
                        }
                    }
                }
                else{
                    #fsa archives
                    my @output = `$bin{'fsarchiver'} archinfo "$directory/$filename" 2>&1`;
                    #this is only designed for one partition per archive, although fsarchiver supports multiple. Not a bug, just as designed :)
                    print join("\n", @output);
                    foreach my $line(@output){
                        if($line=~/Filesystem format:\s+([^\s]+)/){
                            $partitions{$partition_index}{'literalType'} = $1;
                        }
                        if($line=~/Filesystem label:\s+([^\s]+)/){
                            $partitions{$partition_index}{'label'} = "Partition $partition_index ($1)";
                        }
                        if($line=~/Original filesystem size:\s+.*\(([0-9]+) bytes/){
                            $partitions{$partition_index}{'size'} = $1;
                            $partitions{$partition_index}{'sizeHuman'} = $human->format($partitions{$partition_index}{'size'});
                        }
                    }
                }
                $partitions{$partition_index}{'start'} = 0; #we don't need this for restore anyway
                $partitions{$partition_index}{'filename'} = "$directory/$filename";
            }
        }
        closedir(DIR);
        print Dumper(\%partitions);
        
        #select what to restore
        if(scalar keys %partitions > 0){
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
                    $description.="$partitions{$part}{literalType}, ";
                }
            
                my @content =  ( $description, 1 );
                push @displayedPartitions, \@content;
            }
            
            #create a checkbox selector that allows users to select what they want to backup
            my @selectedPartitions = $dialog->checklist(title => "Odroid backup - Please select the partitions you want to restore", text => "Please select the partitions you want to restore",
                        list => \@displayedPartitions);
            print join(",", @selectedPartitions);
            
            if(scalar(@selectedPartitions) > 0 && $selectedPartitions[0] ne '0'){
                #convert selectedPartitions to a hash for simpler lookup
                my %selectedPartitionsHash = map { $_ => 1 } @selectedPartitions;
                
                my $partitionCount = scalar(@selectedPartitions);
                my $progressStep = int(100/$partitionCount);
                
                #select destination disk
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
                my $selectedDisk = $dialog->radiolist(title => "Odroid backup - Please select the disk you wish to restore to. Only the selected partitions will be restored.", text => "Please select the disk you wish to restore to. Only the selected partitions will be restored.",
                                list => \@displayedDisks);
                
                print "Selected disk is: $selectedDisk\n";
                
                if($selectedDisk){
                    #Check that the selectedDisk doesn't have mounted partitions anywhere
                    my %mountedPartitions = getMountedPartitions();
                    my $mountError=undef;
                    foreach my $dev (keys %mountedPartitions){
                        if($dev=~/^\/dev\/${selectedDisk}p?([0-9]+)$/){
                            my $number = $1;
                            #found a mounted partition on the target disk. Complain if it was scheduled for restore, or if MBR is to be restored
                            if(defined $selectedPartitionsHash{$number}){
                                $mountError.="$dev is already mounted on $mountedPartitions{$dev} and is scheduled for restore. ";
                            }
                            if(defined $selectedPartitionsHash{'mbr'}){
                                $mountError.="$dev is already mounted on $mountedPartitions{$dev} and MBR is scheduled for restore. ";
                            }
                        }
                    }
                    
                    if(defined $mountError){
                        $dialog->msgbox(title => "Odroid Backup error", text => "There are mounted filesystems on the target device. $mountError Restore will abort.");
                        exit;
                    }
                    #perform restore
                    #truncate log
                    `echo "Starting restore process" > $logfile`;
                    
                    #if the backend supports it, display a simple progress bar
                    if($dialog->{'_ui_dialog'}->can('gauge_start')){
                        $dialog->{'_ui_dialog'}->gauge_start(title => "Odroid Backup", text => "Performing restore...", percentage => 1);
                    }
                    
                    #restore MBR first
                    if(defined $selectedPartitionsHash{'mbr'}){
                        #we use sfdisk to restore mbr + ebr
                        `echo "*** Restoring MBR ***" >> $logfile`;
                        `$bin{sfdisk} /dev/$selectedDisk < '$partitions{mbr}{filename}' >> $logfile 2>&1 ; echo "Error code: $?" >> $logfile`;
                        #`cat '$directory/partition_table.txt' >> $logfile 2>&1`;
                        
                        #force the kernel to reread the new partition table
                        `$bin{partprobe} -s /dev/$selectedDisk >> $logfile 2>&1`;
                        
                        sleep 2;
                        
                        if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                            $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                            #sleep 5;
                        }
                    }
                    #restore Bootloader second
                    if(defined $selectedPartitionsHash{'bootloader'}){
                        #we use dd to restore bootloader. We skip the partition table even if it's included
                        `echo "*** Restoring Bootloader ***" >> $logfile`;
                        `$bin{dd} if='$partitions{bootloader}{filename}' of=/dev/$selectedDisk bs=512 skip=1 seek=1 >> $logfile 2>&1; echo "Error code: $?" >> $logfile`;
                        
                        #BUT, the odroid will likely not boot if the boot code in the MBR is invalid. So we restore it now
                        `echo "*** Restoring Bootstrap code ***" >> $logfile`;
                        `$bin{dd} if='$partitions{bootloader}{filename}' of=/dev/$selectedDisk bs=446 count=1 >> $logfile 2>&1; echo "Error code: $?" >> $logfile`;
                        
                        if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                            $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                            #sleep 5;
                        }
                    }
                    
                    #restore remaining partitions
                    foreach my $partition (sort keys %selectedPartitionsHash){
                        if($partition =~/^[0-9]+$/){
                            `echo "*** Restoring Partition $partition ***" >> $logfile`;
                            #regular partition. Based on the filesystem we dump it either with fsarchiver or partclone
                            my $partitionNumber = $partition;
                            
                            #note that we need to restore to a partition, not a disk. So we'll need to construct/detect what the corresponding partition numbers are
                            #this program only supports a 1:1 mapping with what's in the archive (nothing fancy). The mapping may be incomplete and flawed for some
                            #use cases - patches welcome
                            
                            my $partitionDev = "";
                            if($selectedDisk =~/mmcblk|loop/){
                                #these ones have a "p" appended between disk and partition (e.g. mmcblk0p1)
                                $partitionDev = $selectedDisk."p".$partitionNumber;
                            }
                            else{
                                #partition goes immediately after the disk name (e.g. sdd1)
                                $partitionDev = $selectedDisk.$partitionNumber;
                            }
                            
                            if($partitions{$partition}{literalType} eq 'vfat' || $partitions{$partition}{literalType} eq 'FAT16' || $partitions{$partition}{literalType} eq 'FAT32'){
                                #we use partclone
                                
                                
                                `$bin{'partclone.restore'} -s '$partitions{$partitionNumber}{filename}' -o '/dev/$partitionDev' >> $logfile 2>&1; echo "Error code: $?" >> $logfile`;
                                if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                                    $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                    #sleep 5;
                                }
                            }
                            elsif($partitions{$partition}{literalType} =~/ext[234]/i){
                                #we use fsarchiver
                                `$bin{'fsarchiver'} restfs '$partitions{$partitionNumber}{filename}' id=0,dest=/dev/$partitionDev >> $logfile 2>&1; echo "Error code: $?" >> $logfile`;
                                if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                                    $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                    #sleep 5;
                                }
                            }
                            else{
                                #not supported filesystem type!
                                $dialog->msgbox(title => "Odroid Backup error", text => "The partition $partition has a non-supported filesystem. Restore will skip it");
                                `echo "*** Skipping partition $partition because it has an unsupported type ($partitions{$partition}{literalType}) ***" >> $logfile`;
                                
                                if($dialog->{'_ui_dialog'}->can('gauge_inc')){
                                    $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                    #sleep 5;
                                }
                            }
                        }
                    }
                }
                
                #finalize progress bar
                if($dialog->{'_ui_dialog'}->can('gauge_set')){
                    $dialog->{'_ui_dialog'}->gauge_set(100);
                    #sleep 5;
                }
                
                #show backup status
                $dialog->textbox(title => "Odroid Backup status", path => $logfile);
                #restore is finished. Program will now exit.
            }
            else{
                $dialog->msgbox(title => "Odroid Backup error", text => "No partitions selected for restore. Program will close");
            }
        }
        else{
            #we found nothing useful in the backup dir
            $dialog->msgbox(title => "Odroid Backup error", text => "No backups found in $directory. Program will close");
        }
    }
    
    
    
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
        #/dev/sdb2 / ext4 rw,relatime,errors=remount-ro,data=ordered 0 0
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

sub firstTimeWarning{
    #issue a warning to let the users know that they might clobber their system if they are not careful
    my $homedir = (getpwuid $>)[7];
    if(! -f $homedir."/.odroid-backup"){
        #running the first time
        $dialog->msgbox(title => "Odroid Backup warning", text => "WARNING: This script attempts to backup and restore eMMCs and SD cards for Odroid systems. It should work with other systems as well, but it was not tested. Since restore can be a dangerous activity take the time to understand what's going on and make sure you're not destroying valuable data. It is wise to test a backup after it was made (image it to a different card and try to boot the system) in order to rule out backup errors. When backup or restore completes you will be presented with a log of what happened. It is wise to review the log, since not all errors are caught by this script (actually none is treated). I am not responsible for corrupted backups, impossible to restore backups, premature baldness or World War 3. This is your only warning! Good luck!");
        
        #create a file in the user's homedir so that we remember he's been warned
        open FILE, ">$homedir/.odroid-backup" or die "Unable to write $homedir/.odroid-backup";
        close FILE;
    }
}
sub checkDependencies{
    #check for sfdisk, partclone, fsarchiver and perl modules
    
    my $message = "";
    
    #check if UI::Dialog is available...
    my $rc = eval{
        require UI::Dialog;
        1;
    };

    if($rc){
        # UI::Dialog loaded and imported successfully
        # initialize it and display errors via UI
        my @ui = ('zenity', 'dialog', 'ascii');
        if(defined $options{'text'}){
            #force rendering only with dialog
            @ui = ('dialog', 'ascii');
        }
        $dialog = new UI::Dialog ( backtitle => "Odroid Backup", debug => 0, width => 400, height => 400, order => \@ui, literal => 1 );
        
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
