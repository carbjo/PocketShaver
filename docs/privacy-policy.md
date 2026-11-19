# PocketShaver Privacy Policy

*Draft dated November 19, 2026*

PocketShaver runs classic Mac OS on your iPhone, iPad, or Mac. The app uses your files, clipboard, and network connection to provide the features described below. PocketShaver has no user accounts, advertising, tracking, or developer-operated analytics. The developer does not sell personal information.

## Local files

PocketShaver reads the installer images, ROMs, disk images, and other files you import or place in its shared folder. The app uses these files to extract a ROM, start the emulator, and read or write guest storage. PocketShaver saves its settings and imported copies on your device. Software running inside the emulator can access files in PocketShaver’s shared folder and mounted disks.

Imported files and settings stay in the app’s local storage until you delete or replace them. You can remove disk images in PocketShaver or manage shared files in Files on iPhone and iPad or Finder on Mac. On iPhone and iPad, use **Delete App** to remove the app and its local data. On Mac, the app’s data folder may remain after uninstalling. Files you exported and copies in your device backups or chosen file providers are managed separately. [About iCloud Backup](https://support.apple.com/en-us/108770)

## Clipboard sharing

PocketShaver can transfer text, formatted text, and images between your device’s system clipboard and the emulated Mac’s clipboard. On iPhone and iPad, **Manual** is the default. You initiate each transfer with a clipboard control. **Automatic sharing** can read and copy clipboard contents while the emulator is running, including when you return to the app. Change this in **Advanced → Clipboard sharing**. Automatic sharing is on by default in the Mac Catalyst version. On Mac, use **Enable clipboard sharing** to turn it on or off.

PocketShaver temporarily holds clipboard contents in memory to convert and transfer them. Content you paste into a guest document can become part of that document. If you use Apple’s Universal Clipboard, items copied to the system clipboard may also be available on your nearby Apple devices. [About Universal Clipboard](https://support.apple.com/en-us/102430)

## Bonjour and guest networking

When you select **Bonjour** in **Network** and allow local network access, PocketShaver advertises its LAN device name, host or client role, and a randomly generated MAC address for the emulated network adapter to nearby PocketShaver devices. You can change the LAN device name in **Network**. The host assigns guest IP addresses and relays guest network traffic to other connected devices. Bonjour sessions are unencrypted. Use this mode on networks and with peers you trust.

PocketShaver stores your LAN name and virtual network addresses locally. If you enable **Autojoin**, it also remembers the host’s virtual address. Turn off **Autojoin** for a host to remove it from that list. You can stop Bonjour discovery and connections by switching to **Slirp** in **Network** or revoking PocketShaver’s **Local Network** permission in your device settings. Slirp lets guest software make network requests through your device’s connection. Other devices and services that guest software contacts may receive the data it sends. [About Local Network permission](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

Network diagnostics may include peer details, addresses, or packet contents in local logs. Your device manages those logs. PocketShaver does not send those logs, your files, clipboard contents, or guest network traffic to the developer.

## Contact

For privacy questions or to request deletion of information you shared with the developer, contact **[privacy contact email]**. The developer uses information you send in a support request to respond and resolve the issue. For general questions, use the [PocketShaver issue tracker](https://github.com/sierra760/PocketShaver/issues). GitHub issues are public.
