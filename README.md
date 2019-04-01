# odroid-backup

This is a frontend tool to guide you to perform backups and restores of your odroid system (and possibly other SBCs as well). It's written in perl because I'm too old to learn python and uses zenity and dialog to build a rudimentary GUI. To install the tool you can download it from my github:

```
$ sudo wget -O /usr/local/bin/odroid-backup.pl https://raw.githubusercontent.com/mad-ady/odroid-backup/master/odroid-backup.pl 
$ sudo chmod a+x /usr/local/bin/odroid-backup.pl
```

The script depends on a bunch of non-standard perl modules and some linux utilities and will display a list of missing dependencies and ways of fixing it when you first run it. To install all dependencies at once run the following:
```
$ sudo apt-get install zenity dialog libnumber-bytes-human-perl libjson-perl fsarchiver udev util-linux coreutils partclone parted mtd-utils
$ sudo perl -MCPAN -e 'install UI::Dialog'
```
The script is designed to run on linux systems - either a PC to which you've hooked up a SD/eMMC through a reader, or directly on the Odroid - sorry Windows fans… Also, the script will create graphical windows if it detects you're running an X11 session, or will fall back to ncurses (display) if you're connected via ssh or terminal (you can manually force this with --text switch).

![alt text](http://imgur.com/m3Pr1NM.png)
> Figure 1. Zenity vs display rendering

To perform a backup, start the tool in a terminal (```sudo odroid-backup.pl```) and select "Backup partitions", select OK 

* (1) You will be presented with a list of removable drives in your system (you can start the program with -a to display all drives - this is the case when running directly on the Odroid, since eMMC and SD are shown as non-removable). Select the desired one and click OK 
* (2) You will then be presented with a list of partitions on that drive. Select the ones you wish to back up 
* (3) Next you will have to select a directory where to save the backups. It's best to have a clean directory 
* (4) Press OK and backup will start (you have a rudimentary progress bar to keep you company) 
* (5) When backup is done you will be presented with a status window with the backup results (and possible errors) 
* (6) The backup files have the same naming convention used in this article.

![alt text](http://imgur.com/To75WZ8.png)
> Figure 2. Backup steps

To perform a restore, start the tool in a terminal (sudo odroid-backup.pl) and select "Restore partitions" and select OK 
* (1) You will have to select the directory holding your precious backups and select OK 
* (2) In the resulting window select which partitions you wish to restore from the backup and select OK 
* (3) Note that the partitions are restored in the same order as they were on the original disk - meaning partition 1 will be the first partition and so on. In the last window you will be asked on which drive to restore the data 
* (4) Enjoy your time watching the progress bar progressing 
* (5) and in the end you will have a status window with the restore results 
* (6) The log file is also saved in /var/log/odroid-backup.log.

![alt text](http://imgur.com/ZAbkngJ.png)
> Figure 3. Restore steps

As you might suspect no piece of software is free of bugs, but hopefully this six step script will have its uses. This script has some shortcomings - such as the zenity windows will not always display the instruction text, so I had to add it to the title bar as well, and there is no validation of the backups or restores. You will have to review the log to see that backup or restore didn't have any problems. One other limitation is that FAT partitions need to be manually unmounted before backup. Ext2/3/4 can be backed-up live. Also, the sfdisk on Ubuntu 14.04 doesn't support JSON output, so it will not work there (I can add support if needed). The program was tested backing up and restoring official HardKernel Linux and Android images, as well as tripleboot images, and so far everything seems to work. Ideas for improvement and patches are welcome as always.

Support thread: http://forum.odroid.com/viewtopic.php?f=52&t=22930
