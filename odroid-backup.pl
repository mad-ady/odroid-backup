#!/usr/bin/perl
use strict;
use warnings;

my $dialog;
my %bin;

my %dependencies = (
'sfdisk' => 'sudo apt-get install sfdisk',
'fsarchiver' => 'sudo apt-get install fsarchiver',
'udevadm' => 'sudo apt-get install udev',
);

checkDependencies();
checkUser();

my $selection = $dialog->radiolist(title => "Odroid Backup", text => "Please select if you want to perform a backup or a restore:", 
                    list => [   'backup', [ 'Backup partitions', 1],
                                'restore', [ 'Restore partitions', 0] ]);
                                
print "$selection\n";

if($selection eq 'backup'){
    #get a list of removable drives and their partitions
    getRemovableDisks();
}
if($selection eq 'restore'){
    
}

sub getRemovableDisks{
    opendir(my $dh, "/sys/block/") || die "Can't opendir /sys/block: $!";
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
            }
            if($line=~/ATTR\{removable\}==\"(.*)\"/){
                $removable = $1;
            }
        }
        
        print "$block\t$model\t$removable\n";
        
    }
    
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
    
    my $rc = eval{
        require UI::Dialog;
        1;
    };

    if($rc){
        # UI::Dialog loaded and imported successfully
        # initialize it and display errors via UI
        $dialog = new UI::Dialog ( backtitle => "Odroid Backup", debug => 0, width => 320, order => [ 'zenity', 'dialog', 'ascii' ], literal => 1 );
        
    }
    else{
        $message .= "UI::Dialog missing - You can install it with sudo apt-get install libui-dialog-perl zenity dialog\n";
    }
    
    foreach my $program (sort keys %dependencies){
        $bin{$program} = `which $program`;
        $bin{$program}=~s/\s+|\r|\n//g;
        if($bin{$program} eq ''){
            $message .= "$program missing - You can install it with $dependencies{$program}\n";
        }
    }
    
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
