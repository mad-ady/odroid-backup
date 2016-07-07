#!/usr/bin/perl
use strict;
use warnings;

my $dialog;
my $sfdisk;
my $fsarchiver;

checkDependencies();
checkUser();

$dialog->msgbox(title => "Odroid Backup", text => "Passed prerequisites test");

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
    
    $sfdisk = `which sfdisk`;
    $sfdisk=~s/\s+|\r|\n//g;
    
    if($sfdisk eq ''){
        $message .= "sfdisk missing - You can install it with sudo apt-get install sfdisk\n";
    }
    
    $fsarchiver = `which fsarchiver`;
    $fsarchiver=~s/\s+|\r|\n//g;
    
    if($fsarchiver eq ''){
        $message .= "fsarchiver missing - You can install it with sudo apt-get install fsarchiver\n";
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
