rem Generic cmd backup script
rem https://www.techrepublic.com/article/how-to-quickly-back-up-just-your-data-in-windows-10-with-robocopys-multi-threaded-feature/
rem Preserve file attributes, and date and time stamps: https://serverfault.com/questions/288631/what-switches-can-robocopy-use-to-preserve-file-and-directory-times-on-the-targe

set source=C:\Some\Source\File\Path
set destination=C:\Some\File\Path
set destination2=C:\Some\Other\File\Path
set name=Name Of Backup

rem Backup to destination
robocopy "%source%" "%destination%\backup" /MIR /COPY:DAT /DCOPY:T /R:10 /W:30 /MT:32 /V /NP /LOG:"%destination%\Backup.log"
move "%destination%\Backup.log" "%destination%\backup"
ren "%destination%\backup" "%name% %date:~-10,2%"-"%date:~-7,2%"-"%date:~-4,4%"-"%time:~0,2%"-"%time:~3,2%"-"%time:~6,2%""

rem Backup to destination2
robocopy "%source%" "%destination2%\backup" /MIR /COPY:DAT /DCOPY:T /R:10 /W:30 /MT:32 /V /NP /LOG:"%destination2%\Backup.log"
move "%destination2%\Backup.log" "%destination2%\backup"
ren "%destination2%\backup" "%name %date:~-10,2%"-"%date:~-7,2%"-"%date:~-4,4%"-"%time:~0,2%"-"%time:~3,2%"-"%time:~6,2%""
