#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case);
use Data::Dumper;
use File::Path qw(make_path);
#use UI::Dialog; #loaded dynamically later
#use Number::Bytes::Human; #loaded dynamically later

my $dialog;
my %bin;
my %options = ();
my %dependencies = (
    'sfdisk' => 'sfdisk',
    'fsarchiver' => 'fsarchiver',
    'udevadm' => 'udev',
    'blockdev' => 'util-linux',
    'blkid' => 'util-linux',
    'dd' => 'coreutils',
    'partclone.vfat' => 'partclone',
    'partclone.btrfs' => 'partclone',
    'partclone.info' => 'partclone',
    'partclone.restore' => 'partclone',
    'partprobe' => 'parted',
    'flash_erase' => 'mtd-utils',
    'umount' => 'mount',
    'mount' => 'mount'
);

my $logfile = '/var/log/odroid-backup.log';

GetOptions(\%options, 'help|h', 'allDisks|a', "ASCII|A", 'text|t', 'backup', 'restore', 'disk=s', 'partitions=s', 'directory=s');
if(defined $options{help}){
    print "Odroid Backup program\n
Usage $0 options
Options

--help|-h       Print this message
--allDisks|-a   Display all disks in the selector (by default only removable disks are shown)
--text|-t       Force rendering with dialog even if zenity is available
--ASCII|-A	Force rendering with ASCII
--backup    Do a backup
--restore   Do a restore
--disk      Disk to backup/restore to (e.g.: sda, sdb, mmcblk0, mmcblk1, etc)
--partitions List of partitions to backup/restore. Valid names are in this format:
            bootloader,mbr,/dev/sdd1 -- when backuping
            bootloader,mbr,1 -- when restoring
--directory Directory to backup to or to restore from
";
    exit 0;
}

#validate the command-line options supplied that have mandatory arguments
foreach my $switch ('disk','partitions','directory'){
    if(defined $options{$switch} && $options{$switch} eq ''){
        die "Command-line option $switch requires an argument";
    }
}

#determine if we're going to run only with command-line parameters, or if we need GUI elements as well
my $cmdlineOnly = 0;
if((defined $options{backup} || defined $options{restore}) &&
    defined $options{disk} && defined $options{partitions} && defined $options{directory}){
    $cmdlineOnly = 1;
}

checkDependencies();
checkUser();
firstTimeWarning();

my $human = Number::Bytes::Human->new(bs => 1024, si => 1);

my $mainOperation;
if(defined $options{'backup'} || defined $options{'restore'}){
    if(defined $options{'backup'}){
        $mainOperation = 'backup';
    }
    if(defined $options{'restore'}){
        $mainOperation = 'restore';
    }
    if(defined $options{'restore'} && defined $options{'backup'}){
        #this is a problem - be more specific
        die("Error: Both backup and restore options were specified, which is ambiguous.");
    }

}
else {
    $mainOperation = $dialog->radiolist(title                                               =>
        "Odroid Backup - Please select if you want to perform a backup or a restore:", text =>
        "Please select if you want to perform a backup or a restore:",
        list                                                                                =>
        [ 'backup', [ 'Backup partitions', 1 ],
            'restore', [ 'Restore partitions', 0 ] ]);

    print "MainOperation:$mainOperation\n";
}

my $error = 0;

if($mainOperation eq '0'){
    die "Unable to display window for selection. Try running with --text";
}

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
    my $selectedDisk;
    if(defined $options{'disk'}){
        #validate if the user option is part of the disks we were going to display
        my $valid = 0;
        foreach my $disk (@displayedDisks){
            if($disk eq $options{'disk'}){
                $valid = 1;
                $selectedDisk = $options{'disk'};
            }
        }
        if(!$valid){
            die "Disk $options{'disk'} is not a valid disk. Valid options are: ".join(" ", sort keys %disks);
        }
    }
    else{
        $selectedDisk = $dialog->radiolist(title => "Odroid backup - Please select the disk you wish to backup", text => "Please select the disk you wish to backup",
                    list => \@displayedDisks);
    }
    
#    print $selectedDisk;
    
    if($selectedDisk){
        if($selectedDisk=~/mtd/){
            #this is a flash device, use dd to back it up
            my $directory;
            if(defined $options{'directory'}) {
                $directory = $options{'directory'};
            }
            else{
                 $directory = $dialog->dselect('path' => ".");
            }
            print $directory;
            if ($directory) {
                #the directory might not exist. Test if it exists or create it
                if (!-d "$directory") {
                    make_path($directory);
                }
                #truncate log
                `echo "Starting backup process" > $logfile`;

                `$bin{dd} if=/dev/$selectedDisk of="$directory/flash_$selectedDisk.bin" >> $logfile 2>&1`;
                $error = $? >> 8;
                `echo "Error code: $error" >> $logfile 2>&1`;

                my $size = -s "$directory/flash_$selectedDisk.bin";
                `echo "*** MTD $selectedDisk backup size: $size bytes ***" >> $logfile`;

                #show backup status
                textbox("Odroid Backup status", $logfile);
                #backup is finished. Program will now exit.
            }
        }
        else {
            #get a list of partitions from the disk and their type
            my %partitions = getPartitions($selectedDisk);
            print "Listing partitions on disk $selectedDisk...\n";
            print Dumper(\%partitions);

            #convert the partitions hash to an array the way checklist expects
            my @displayedPartitions = ();
            foreach my $part (sort keys %partitions) {
                push @displayedPartitions, $part;
                my $description = "";
                if (defined $partitions{$part}{label}) {
                    $description .= "$partitions{$part}{label}, ";
                }
                $description .= "$partitions{$part}{sizeHuman}, ";

                if (defined $partitions{$part}{literalType}) {
                    $description .= "$partitions{$part}{literalType} ($partitions{$part}{type}), ";
                }
                else {
                    $description .= "type $partitions{$part}{type}, ";
                }

                if (defined $partitions{$part}{mounted}) {
                    $description .= "mounted on $partitions{$part}{mounted}, ";
                }

                if (defined $partitions{$part}{uuid}) {
                    $description .= "UUID $partitions{$part}{uuid}, ";
                }

                $description .= "start sector $partitions{$part}{start}";
                my @content = ($description, 1);
                push @displayedPartitions, \@content;
            }
            my @selectedPartitions;
            if(defined $options{'partitions'}){
                #partitions should be a comma separated list - convert it to array
                @selectedPartitions = split(',', $options{'partitions'});
                #validate that the names proposed exist in the partition list to be displayed
                foreach my $partition (@selectedPartitions){
                    if(!defined $partitions{$partition}){
                        #the user selection is wrong
                        die "Partition $partition is not a valid selection. Valid options are: ". join(", ", sort keys %partitions);
                    }
                }
            }
            else {
                #create a checkbox selector that allows users to select what they want to backup
                @selectedPartitions = $dialog->checklist(title                            =>
                    "Odroid backup - Please select the partitions you want to back-up", text =>
                    "Please select the partitions you want to back-up",
                    list                                                                     => \@displayedPartitions);
            }
            #fix an extra "$" being appended to the selected element sometimes by zenity
#            print "Partition list after select box: " . join(",", @selectedPartitions);
            for (my $i = 0; $i < scalar(@selectedPartitions); $i++) {
                if ($selectedPartitions[$i] =~ /\$$/) {
                    $selectedPartitions[$i] =~ s/\$$//g;
                }
            }
            print "Using partition list: " . join(",", @selectedPartitions)."\n";

            if (scalar(@selectedPartitions) > 0 && $selectedPartitions[0] ne '0') {
                #select a destination directory to dump to
                my $directory;
                if(defined $options{'directory'}) {
                    $directory = $options{'directory'};
                }
                else {
                    $directory = $dialog->dselect('path' => ".");
                }
#                print $directory;
                if ($directory) {
                    #the directory might not exist. Test if it exists or create it
                    if (!-d "$directory") {
                        make_path($directory);
                    }
                    #truncate log
                    `echo "Starting backup process" > $logfile`;

                    my $partitionCount = scalar(@selectedPartitions);
                    my $progressStep = int(100 / $partitionCount);

                    foreach my $partition (reverse @selectedPartitions) {
                        #log something
                        `echo "*** Starting to backup $partition ***" >> $logfile`;
                        if(!$cmdlineOnly) {
                            #if the backend supports it, display a simple progress bar
                            if ($dialog->{'_ui_dialog'}->can('gauge_start')) {
                                $dialog->{'_ui_dialog'}->gauge_start(title => "Odroid Backup", text =>
                                    "Performing backup...", percentage     => 1);
                            }
                        }
                        if ($partition eq 'mbr') {
                            #we use sfdisk to dump mbr + ebr
                            `$bin{sfdisk} -d /dev/$selectedDisk > '$directory/partition_table.txt'`;
                            $error = $? >> 8;
                            `echo "Error code: $error" >> $logfile 2>&1`;

                            `cat '$directory/partition_table.txt' >> $logfile 2>&1`;
                            if(!$cmdlineOnly) {
                                if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                    $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                    #sleep 5;
                                }
                            }
                        }
                        elsif ($partition eq 'bootloader') {
                            #we use dd to dump bootloader. We dump the partition table as a binary, just to be safe
                            `$bin{dd} if=/dev/$selectedDisk of="$directory/bootloader.bin" bs=512 count=$partitions{bootloader}{end} >> $logfile 2>&1`;
                            $error = $? >> 8;
                            `echo "Error code: $error" >> $logfile 2>&1`;

                            my $size = -s "$directory/bootloader.bin";
                            `echo "*** Bootloader backup size: $size bytes ***" >> $logfile`;
                            if(!$cmdlineOnly) {
                                if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                    $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                    #sleep 5;
                                }
                            }
                        }
                        else {
                            #regular partition. Based on the filesystem we dump it either with fsarchiver or partclone
                            $partition =~ /([0-9]+)$/;
                            my $partitionNumber = $1;

                            if ($partitions{$partition}{literalType} eq 'vfat' || $partitions{$partition}{literalType} eq 'btrfs') {
                                #we use partclone
                                my $partcloneVersion = 'partclone.' . $partitions{$partition}{literalType};
                                `echo "Using partclone binary: $partcloneVersion" >> $logfile 2>&1`;
                                if(defined $partitions{$partition}{'mounted'}){
                                    `echo "Unmounting $partitions{$partition}{'mounted'}..." >> $logfile`;
                                    `$bin{umount} $partition >> $logfile 2>&1`; #partition can't be mounted while backing it up (eg. btrfs), so let's un-mount it
                                }

                                `$bin{"$partcloneVersion"} -c -s $partition -o "$directory/partition_${partitionNumber}.img" >> $logfile 2>&1`;
                                $error = $? >> 8;
                                `echo "Error code: $error" >> $logfile 2>&1`;

                                #if the partition was umounted, it's nice to try to mount it back - to prevent other problems
                                if(defined $partitions{$partition}{'mounted'}){
                                    `echo "Mounting back $partitions{$partition}{'mounted'} (if it's in fstab)..." >> $logfile`;
                                    `$bin{mount} $partitions{$partition}{'mounted'} >> $logfile 2>&1`;
                                }

                                `$bin{'partclone.info'} -s "$directory/partition_${partitionNumber}.img" >> $logfile 2>&1`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                            elsif ($partitions{$partition}{literalType} =~ /ext[234]/) {
                                #we use fsarchiver
                                `$bin{'fsarchiver'} -A savefs "$directory/partition_${partitionNumber}.fsa" $partition >> $logfile 2>&1`;
                                $error = $? >> 8;
                                `echo "Error code: $error" >> $logfile 2>&1`;

                                `$bin{'fsarchiver'} archinfo "$directory/partition_${partitionNumber}.fsa" >> $logfile 2>&1`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                            else {
                                #not supported filesystem type!
                                messagebox("Odroid Backup error", "The partition $partition has a non-supported filesystem. Backup will skip it");
                                `echo "*** Skipping partition $partition because it has an unsupported type ($partitions{$partition}{literalType}) ***" >> $logfile`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                        }
                    }

                    if(!$cmdlineOnly) {
                        #finalize progress bar
                        if ($dialog->{'_ui_dialog'}->can('gauge_set')) {
                            $dialog->{'_ui_dialog'}->gauge_set(100);
                            #sleep 5;
                        }
                    }

                    #show backup status
                    textbox("Odroid Backup status", $logfile);
                    #backup is finished. Program will now exit.
                }
                else {
                    messagebox("Odroid Backup error", "Unrecognized directory. Try running the command with --directory /path/to/directory");
                }
            }
            else {
                messagebox("Odroid Backup error", "No partitions selected for backup. Program will close");
            }
        }
        
    }
    else{
            messagebox("Odroid Backup error", "No disks selected for backup. Program will close");
    }
}
if($mainOperation eq 'restore'){
    #select source directory
    my $directory;
    if(defined $options{'directory'}) {
        $directory = $options{'directory'};
    }
    else {
        $directory = $dialog->dselect(title => "Odroid backup - Please select the directory holding your backup", text
                                            => "Please select the directory holding your backup", 'path' => ".");
    }
#    print $directory;
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
            if($filename=~/flash_(.*)\.bin/) {
                my $mtddevice = $1;
                #sanity check - the image to be flashed equals the current target size
                my %localDisks = getRemovableDisks();
                if(defined $localDisks{$mtddevice}){
                    my $backupsize = -s "$directory/$filename";
                    if($backupsize == $localDisks{$mtddevice}{'size'}) {
                        $partitions{'flash_' . $mtddevice}{'literalType'} = "bin";
                        $partitions{'flash_' . $mtddevice}{'size'} = $backupsize;
                        $partitions{'flash_' . $mtddevice}{'sizeHuman'} = $human->format($backupsize);
                        $partitions{'flash_' . $mtddevice}{'label'} = "MTD Flash $mtddevice";
                        $partitions{'flash_' . $mtddevice}{'filename'} = "$directory/$filename";
                    }

                }
                else{
                    #silently skip non-matching flash sizes
                }
            }
        }
        closedir(DIR);
        print "Read the following restorable data from the archive directory:\n";
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
            my @selectedPartitions;
            if(defined $options{'partitions'}){
                #partitions should be a comma separated list - convert it to array
                @selectedPartitions = split(',', $options{'partitions'});
                #validate that the names proposed exist in the partition list to be displayed
                foreach my $partition (@selectedPartitions){
                    if(!defined $partitions{$partition}){
                        #the user selection is wrong
                        die "Partition $partition is not a valid selection. Valid options are: ". join(", ", sort keys %partitions);
                    }
                }
            }
            else {
                #create a checkbox selector that allows users to select what they want to backup
                @selectedPartitions = $dialog->checklist(title                            =>
                    "Odroid backup - Please select the partitions you want to restore", text =>
                    "Please select the partitions you want to restore",
                    list                                                                     => \@displayedPartitions);
            }
            #fix an extra "$" being appended to the selected element sometimes by zenity
       	    #print "Partition list after select box: ". join(",", @selectedPartitions);
            for (my $i=0; $i<scalar(@selectedPartitions); $i++){
               if($selectedPartitions[$i]=~/\$$/){
                       $selectedPartitions[$i]=~s/\$$//g;
               }
            }
            print "Selected to restore the following partitions: ". join(",", @selectedPartitions)."\n";

            
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
                my $selectedDisk;
                if(defined $options{'disk'}){
                    #validate if the user option is part of the disks we were going to display
                    my $valid = 0;
                    foreach my $disk (@displayedDisks){
                        if($disk eq $options{'disk'}){
                            $valid = 1;
                            $selectedDisk = $options{'disk'};
                        }
                    }
                    if(!$valid){
                        die "Disk $options{'disk'} is not a valid disk. Valid options are: ".join(" ", sort keys %disks);
                    }
                }
                else {
                    $selectedDisk = $dialog->radiolist(title =>
                        "Odroid backup - Please select the disk you wish to restore to. Only the selected partitions will be restored.",
                        text                                    =>
                        "Please select the disk you wish to restore to. Only the selected partitions will be restored.",
                        list                                    => \@displayedDisks);
                }
                print "Selected disk to restore to is: $selectedDisk\n";
                
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
                        messagebox("Odroid Backup error", "There are mounted filesystems on the target device. $mountError Restore will abort.");
                        exit;
                    }
                    #perform restore
                    #truncate log
                    `echo "Starting restore process" > $logfile`;

                    if(!$cmdlineOnly) {
                        #if the backend supports it, display a simple progress bar
                        if ($dialog->{'_ui_dialog'}->can('gauge_start')) {
                            $dialog->{'_ui_dialog'}->gauge_start(title => "Odroid Backup", text =>
                                "Performing restore...", percentage    => 1);
                        }
                    }
                    
                    #restore MBR first
                    if(defined $selectedPartitionsHash{'mbr'}){
                        #we use sfdisk to restore mbr + ebr
                        `echo "*** Restoring MBR ***" >> $logfile`;
                        `$bin{sfdisk} /dev/$selectedDisk < '$partitions{mbr}{filename}' >> $logfile 2>&1 `;
                        $error = $? >> 8;
                        `echo "Error code: $error" >> $logfile 2>&1`;

                        #force the kernel to reread the new partition table
                        `$bin{partprobe} -s /dev/$selectedDisk >> $logfile 2>&1`;
                        
                        sleep 2;

                        if(!$cmdlineOnly) {
                            if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                #sleep 5;
                            }
                        }
                    }
                    #restore Bootloader second
                    if(defined $selectedPartitionsHash{'bootloader'}){
                        #we use dd to restore bootloader. We skip the partition table even if it's included
                        `echo "*** Restoring Bootloader ***" >> $logfile`;
                        `$bin{dd} if='$partitions{bootloader}{filename}' of=/dev/$selectedDisk bs=512 skip=1 seek=1 >> $logfile 2>&1`;
                        $error = $? >> 8;
                        `echo "Error code: $error" >> $logfile 2>&1`;

                        
                        #BUT, the odroid will likely not boot if the boot code in the MBR is invalid. So we restore it now
                        `echo "*** Restoring Bootstrap code ***" >> $logfile`;
                        `$bin{dd} if='$partitions{bootloader}{filename}' of=/dev/$selectedDisk bs=446 count=1 >> $logfile 2>&1`;
                        $error = $? >> 8;
                        `echo "Error code: $error" >> $logfile 2>&1`;

                        if(!$cmdlineOnly) {
                            if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                #sleep 5;
                            }
                        }
                    }

                    #restore flash
                    foreach my $part (keys %selectedPartitionsHash){
                        if($part=~/^flash_(.*)/){
                            my $mtd = $1;
                            #this has been checked and should be restoreable on the system (should already exist)
                            `echo "*** Restoring $mtd ***" >> $logfile`;
                            `echo "Erasing $mtd..." >> $logfile`;
                            #first erase it
                            `echo $bin{flash_erase} -q /dev/$mtd 0 0 >> $logfile 2>&1`;
                            $error = $? >> 8;
                            `echo "Error code: $error" >> $logfile 2>&1`;
                            #next, write it
                            `$bin{dd} if='$partitions{$part}{filename}' of=/dev/$mtd bs=4096 >> $logfile 2>&1`;
                            $error = $? >> 8;
                            `echo "Error code: $error" >> $logfile 2>&1`;

                            if(!$cmdlineOnly) {
                                if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                    $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                    #sleep 5;
                                }
                            }
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
                            
                            if($partitions{$partition}{literalType} eq 'vfat' || $partitions{$partition}{literalType} eq 'btrfs' || $partitions{$partition}{literalType} eq 'BTRFS' || $partitions{$partition}{literalType} eq 'FAT16' || $partitions{$partition}{literalType} eq 'FAT32'){
                                #we use partclone
                                `$bin{'partclone.restore'} -s '$partitions{$partitionNumber}{filename}' -o '/dev/$partitionDev' >> $logfile 2>&1`;
                                $error = $? >> 8;
                                `echo "Error code: $error" >> $logfile 2>&1`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                            elsif($partitions{$partition}{literalType} =~/ext[234]/i){
                                #we use fsarchiver
                                `$bin{'fsarchiver'} restfs '$partitions{$partitionNumber}{filename}' id=0,dest=/dev/$partitionDev >> $logfile 2>&1`;
                                $error = $? >> 8;
                                `echo "Error code: $error" >> $logfile 2>&1`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                            elsif($partitions{$partition}{type} eq '5'){
                                #extended partition - nothing to do, it will be restored via sfdisk automatically
                            }
                            else{
                                #not supported filesystem type!
                                messagebox("Odroid Backup error", "The partition $partition has a non-supported filesystem. Restore will skip it");
                                `echo "*** Skipping partition $partition because it has an unsupported type ($partitions{$partition}{literalType}) ***" >> $logfile`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                        }
                    }
                }

                if(!$cmdlineOnly) {
                    #finalize progress bar
                    if ($dialog->{'_ui_dialog'}->can('gauge_set')) {
                        $dialog->{'_ui_dialog'}->gauge_set(100);
                        #sleep 5;
                    }
                }
                
                #show backup status
                textbox("Odroid Backup status", $logfile);
                #restore is finished. Program will now exit.
            }
            else{
                messagebox("Odroid Backup error", "No partitions selected for restore. Program will close");
            }
        }
        else{
            #we found nothing useful in the backup dir
            messagebox("Odroid Backup error", "No backups found in $directory. Program will close");
        }
    }
    else{
        messagebox("Odroid Backup error", "Unrecognized directory. Try running the command with --directory /path/to/directory");
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
#        print "/sys/block/$block\n";
        my @info = `$bin{udevadm} info -a --path=/sys/block/$block 2>/dev/null`;
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
#        print "$block\t$model\t$removable\n";
    }
    # Also look for NAND flash and show it as a disk
    if(open NAND, "/proc/mtd"){
        while(<NAND>){
            if(/^([^\s]+):\s+([0-9a-f]+)\s+([0-9a-f]+)\s+\"([^\"]+)\"/){
                my $mtddevice = $1;
                my $hexsize = $2;
                my $erase = $3;
                my $name = $4;
                $disks{$mtddevice}{sizeHuman} = $human->format(hex($hexsize));
                $disks{$mtddevice}{size} = hex($hexsize);
                $disks{$mtddevice}{model} = "MTD Flash $name";
                $disks{$mtddevice}{removable} = "non-removable";
            }
        }
    }

    return %disks;
    
}

sub getDiskSize{
    my $disk = shift;
    $disk = "/dev/$disk" if($disk !~ /^\/dev\//);
#    print Dumper(\$disk);
    my $size = `$bin{blockdev} --getsize64 $disk 2>/dev/null`;
    $size=~s/\r|\n//g;
    return $size;
}

sub checkUser{
    if($< != 0){
        #needs to run as root
        messagebox("Odroid Backup error", "You need to run this program as root");
        exit 2;
    }
}

sub firstTimeWarning{
    #issue a warning to let the users know that they might clobber their system if they are not careful
    my $homedir = (getpwuid $>)[7];
    if(! -f $homedir."/.odroid-backup"){
        #running the first time
        messagebox("Odroid Backup warning", "WARNING: This script attempts to backup and restore eMMCs and SD cards for Odroid systems. It should work with other systems as well, but it was not tested. Since restore can be a dangerous activity take the time to understand what's going on and make sure you're not destroying valuable data. It is wise to test a backup after it was made (image it to a different card and try to boot the system) in order to rule out backup errors. When backup or restore completes you will be presented with a log of what happened. It is wise to review the log, since not all errors are caught by this script (actually none is treated). I am not responsible for corrupted backups, impossible to restore backups, premature baldness or World War 3. This is your only warning! Good luck!");
        
        #create a file in the user's homedir so that we remember he's been warned
        open FILE, ">$homedir/.odroid-backup" or die "Unable to write $homedir/.odroid-backup";
        close FILE;
    }
}

sub messagebox{
    my $title = shift;
    my $text = shift;
    if($cmdlineOnly){
        print "$title: $text\n";
    }
    else {
        $dialog->msgbox(title => $title, text => $text);
    }
}

sub textbox{
    my $title = shift;
    my $file = shift;
    if($cmdlineOnly){
        print "$title:\n";
        print `cat "$file"`;
        print "\n";
    }
    else {
        $dialog->textbox(title => $title, path => $file);
    }
}

sub checkDependencies{
    #check for sfdisk, partclone, fsarchiver and perl modules
    
    my $message = "";
    my $rc = 0;
    my $evalError = "";
    if(!$cmdlineOnly) {
        #check if UI::Dialog is available...
        $rc = eval {
            require UI::Dialog;
            1;
        };
        if(! defined $rc){
            $evalError = $@;
            print "$evalError\n";
        }
    }
    print "DBG: rc=$rc\n";
    my %toinstall = ();
    my %cpanToInstall = ();

    if(!$cmdlineOnly) {
        if (defined $rc) {
            # UI::Dialog loaded and imported successfully
            # initialize it and display errors via UI
            my @ui = ('zenity', 'dialog', 'ascii');
            if (defined $options{'text'}) {
                #force rendering only with dialog
                @ui = ('dialog', 'ascii');
            }
            if (defined $options{'ASCII'}) {
                #force rendering only with ascii
                @ui = ('ascii');
            }
            $dialog = new UI::Dialog (backtitle => "Odroid Backup", debug => 0, width => 400, height => 400,
                                        order => \@ui, literal => 1);
            print "DBG: dialog: $dialog\n";
        }
        else {
            $message .= "UI::Dialog missing...\n";
            $cpanToInstall{'UI::Dialog'} = 1;
            $toinstall{'zenity'} = 1;
            $toinstall{'dialog'} = 1;
        }
    }
    
    #check if other perl modules are available
    my $readable = eval{
        require Number::Bytes::Human;
        1;
    };
    
    if(!$readable){
        $message .= "Number::Bytes::Human missing...\n";
        $toinstall{'libnumber-bytes-human-perl'} = 1;
    }
    
    my $json = eval{
        require JSON;
        1;
    };
    if(!$json){
        $message .= "JSON missing...\n";
        $toinstall{'libjson-perl'} = 1;
    }
    
    #check if system binaries are available
    
    foreach my $program (sort keys %dependencies){
        $bin{$program} = `which $program`;
        $bin{$program}=~s/\s+|\r|\n//g;
        if($bin{$program} eq ''){
            $message .= "$program missing...\n";
            $toinstall{$dependencies{$program}}=1;
        }
    }

    if(scalar keys %toinstall > 0){
        my $packages = join(" ", keys %toinstall);
        $message .= "To install missing dependencies run\n  sudo apt-get install $packages\n";
    }

    #check if CPAN modules are available
    if(scalar keys %cpanToInstall) {
        $message .= "To install missing perl modules run\n";
        foreach my $module (sort keys %cpanToInstall) {
            $message .= "  sudo perl -MCPAN -e 'install $module'\n";
        }
    }

    #complain if needed
    if($message ne ''){
        $message = "Odroid Backup needs the following packages to function:\n\n$message";

        messagebox("Odroid Backup error", $message);
        exit 1;
    }
}
