//
//  hfs-ios.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-10-13.
//

#import <Foundation/Foundation.h>

typedef unsigned int                    UInt32;
typedef unsigned short                  u_int16_t;
typedef short                   int16_t;
typedef unsigned int            u_int32_t;
typedef signed char           int8_t;
typedef unsigned char           u_int8_t;
typedef int                     int32_t;
typedef unsigned long long      u_int64_t;

typedef UInt32                          HFSCatalogNodeID;
typedef UInt32                          TextEncoding;

struct HFSExtentDescriptor {
	u_int16_t 	startBlock;		/* first allocation block */
	u_int16_t 	blockCount;		/* number of allocation blocks */
} __attribute__((aligned(2), packed));
typedef struct HFSExtentDescriptor HFSExtentDescriptor;

struct HFSPlusExtentDescriptor {
	u_int32_t 	startBlock;		/* first allocation block */
	u_int32_t 	blockCount;		/* number of allocation blocks */
} __attribute__((aligned(2), packed));
typedef struct HFSPlusExtentDescriptor HFSPlusExtentDescriptor;

struct FndrFileInfo {
	u_int32_t 	fdType;		/* file type */
	u_int32_t 	fdCreator;	/* file creator */
	u_int16_t 	fdFlags;	/* Finder flags */
	struct {
		int16_t	v;		/* file's location */
		int16_t	h;
	} fdLocation;
	int16_t 	opaque;
} __attribute__((aligned(2), packed));
typedef struct FndrFileInfo FndrFileInfo;

struct FndrOpaqueInfo {
	int8_t opaque[16];
} __attribute__((aligned(2), packed));
typedef struct FndrOpaqueInfo FndrOpaqueInfo;

typedef HFSExtentDescriptor HFSExtentRecord[3];

struct HFSCatalogFile {
	int16_t 		recordType;		/* == kHFSFileRecord */
	u_int8_t 		flags;			/* file flags */
	int8_t 			fileType;		/* file type (unused ?) */
	FndrFileInfo 		userInfo;		/* Finder information */
	u_int32_t 		fileID;			/* file ID */
	u_int16_t 		dataStartBlock;		/* not used - set to zero */
	int32_t 		dataLogicalSize;	/* logical EOF of data fork */
	int32_t 		dataPhysicalSize;	/* physical EOF of data fork */
	u_int16_t		rsrcStartBlock;		/* not used - set to zero */
	int32_t			rsrcLogicalSize;	/* logical EOF of resource fork */
	int32_t			rsrcPhysicalSize;	/* physical EOF of resource fork */
	u_int32_t		createDate;		/* date and time of creation */
	u_int32_t		modifyDate;		/* date and time of last modification */
	u_int32_t		backupDate;		/* date and time of last backup */
	FndrOpaqueInfo		finderInfo;		/* additional Finder information */
	u_int16_t		clumpSize;		/* file clump size (not used) */
	HFSExtentRecord		dataExtents;		/* first data fork extent record */
	HFSExtentRecord		rsrcExtents;		/* first resource fork extent record */
	u_int32_t		reserved;		/* reserved - initialized as zero */
} __attribute__((aligned(2), packed));
typedef struct HFSCatalogFile HFSCatalogFile;

struct FndrDirInfo {
	struct {			/* folder's window rectangle */
		int16_t	top;
		int16_t	left;
		int16_t	bottom;
		int16_t	right;
	} frRect;
	unsigned short 	frFlags;	/* Finder flags */
	struct {
		u_int16_t	v;		/* folder's location */
		u_int16_t	h;
	} frLocation;
	int16_t 	opaque;
} __attribute__((aligned(2), packed));
typedef struct FndrDirInfo FndrDirInfo;

struct HFSCatalogFolder {
	int16_t 		recordType;		/* == kHFSFolderRecord */
	u_int16_t 		flags;			/* folder flags */
	u_int16_t 		valence;		/* folder valence */
	u_int32_t		folderID;		/* folder ID */
	u_int32_t 		createDate;		/* date and time of creation */
	u_int32_t 		modifyDate;		/* date and time of last modification */
	u_int32_t 		backupDate;		/* date and time of last backup */
	FndrDirInfo 		userInfo;		/* Finder information */
	FndrOpaqueInfo		finderInfo;		/* additional Finder information */
	u_int32_t 		reserved[4];		/* reserved - initialized as zero */
} __attribute__((aligned(2), packed));
typedef struct HFSCatalogFolder HFSCatalogFolder;

struct HFSPlusBSDInfo {
	u_int32_t 	ownerID;	/* user-id of owner or hard link chain previous link */
	u_int32_t 	groupID;	/* group-id of owner or hard link chain next link */
	u_int8_t 	adminFlags;	/* super-user changeable flags */
	u_int8_t 	ownerFlags;	/* owner changeable flags */
	u_int16_t 	fileMode;	/* file type and permission bits */
	union {
		u_int32_t	iNodeNum;	/* indirect node number (hard links only) */
		u_int32_t	linkCount;	/* links that refer to this indirect node */
		u_int32_t	rawDevice;	/* special file device (FBLK and FCHR only) */
	} special;
} __attribute__((aligned(2), packed));
typedef struct HFSPlusBSDInfo HFSPlusBSDInfo;

typedef HFSPlusExtentDescriptor HFSPlusExtentRecord[8];

struct HFSPlusForkData {
	u_int64_t 		logicalSize;	/* fork's logical size in bytes */
	u_int32_t 		clumpSize;	/* fork's clump size in bytes */
	u_int32_t 		totalBlocks;	/* total blocks used by this fork */
	HFSPlusExtentRecord 	extents;	/* initial set of extents */
} __attribute__((aligned(2), packed));
typedef struct HFSPlusForkData HFSPlusForkData;

struct HFSPlusCatalogFile {
	int16_t 		recordType;		/* == kHFSPlusFileRecord */
	u_int16_t 		flags;			/* file flags */
	u_int32_t 		reserved1;		/* reserved - initialized as zero */
	u_int32_t 		fileID;			/* file ID */
	u_int32_t 		createDate;		/* date and time of creation */
	u_int32_t 		contentModDate;		/* date and time of last content modification */
	u_int32_t 		attributeModDate;	/* date and time of last attribute modification */
	u_int32_t 		accessDate;		/* date and time of last access (MacOS X only) */
	u_int32_t 		backupDate;		/* date and time of last backup */
	HFSPlusBSDInfo 		bsdInfo;		/* permissions (for MacOS X) */
	FndrFileInfo 		userInfo;		/* Finder information */
	FndrOpaqueInfo	 	finderInfo;		/* additional Finder information */
	u_int32_t 		textEncoding;		/* hint for name conversions */
	u_int32_t 		reserved2;		/* reserved - initialized as zero */

	/* Note: these start on double long (64 bit) boundary */
	HFSPlusForkData 	dataFork;		/* size and block data for data fork */
	HFSPlusForkData 	resourceFork;		/* size and block data for resource fork */
} __attribute__((aligned(2), packed));
typedef struct HFSPlusCatalogFile HFSPlusCatalogFile;

struct HFSPlusCatalogFolder {
	int16_t 		recordType;		/* == kHFSPlusFolderRecord */
	u_int16_t 		flags;			/* file flags */
	u_int32_t 		valence;		/* folder's item count */
	u_int32_t 		folderID;		/* folder ID */
	u_int32_t 		createDate;		/* date and time of creation */
	u_int32_t 		contentModDate;		/* date and time of last content modification */
	u_int32_t 		attributeModDate;	/* date and time of last attribute modification */
	u_int32_t 		accessDate;		/* date and time of last access (MacOS X only) */
	u_int32_t 		backupDate;		/* date and time of last backup */
	HFSPlusBSDInfo		bsdInfo;		/* permissions (for MacOS X) */
	FndrDirInfo 		userInfo;		/* Finder information */
	FndrOpaqueInfo	 	finderInfo;		/* additional Finder information */
	u_int32_t 		textEncoding;		/* hint for name conversions */
	u_int32_t 		folderCount;		/* number of enclosed folders, active when HasFolderCount is set */
} __attribute__((aligned(2), packed));
typedef struct HFSPlusCatalogFolder HFSPlusCatalogFolder;

struct HFSUniStr255 {
	u_int16_t	length;		/* number of unicode characters */
	u_int16_t	unicode[255];	/* unicode characters */
} __attribute__((aligned(2), packed));
typedef struct HFSUniStr255 HFSUniStr255;
typedef const HFSUniStr255 *ConstHFSUniStr255Param;

enum {
	kHFSMaxVolumeNameChars		= 27,
	kHFSMaxFileNameChars		= 31,
	kHFSPlusMaxFileNameChars	= 255
};

struct HFSCatalogKey {
	u_int8_t 	keyLength;		/* key length (in bytes) */
	u_int8_t 	reserved;		/* reserved (set to zero) */
	u_int32_t 	parentID;		/* parent folder ID */
	u_int8_t 	nodeName[kHFSMaxFileNameChars + 1]; /* catalog node name */
} __attribute__((aligned(2), packed));
typedef struct HFSCatalogKey HFSCatalogKey;

typedef struct OpaqueTextToUnicodeInfo*  TextToUnicodeInfo;
typedef struct OpaqueUnicodeToTextInfo*  UnicodeToTextInfo;

enum {
	kTextEncodingUnicodeDefault   = 0x0100
};

enum {
	kUnicodeUTF8Format = 2
};

enum {
	kHFSRootParentID		= 1,	/* Parent ID of the root folder */
	kHFSRootFolderID		= 2,	/* Folder ID of the root folder */
	kHFSExtentsFileID		= 3,	/* File ID of the extents file */
	kHFSCatalogFileID		= 4,	/* File ID of the catalog file */
	kHFSBadBlockFileID		= 5,	/* File ID of the bad allocation block file */
	kHFSAllocationFileID		= 6,	/* File ID of the allocation file (HFS Plus only) */
	kHFSStartupFileID		= 7,	/* File ID of the startup file (HFS Plus only) */
	kHFSAttributesFileID		= 8,	/* File ID of the attribute file (HFS Plus only) */
	kHFSAttributeDataFileID         = 13,	/* Used in Mac OS X runtime for extent based attributes */
											/* kHFSAttributeDataFileID is never stored on disk. */
	kHFSRepairCatalogFileID		= 14,	/* Used when rebuilding Catalog B-tree */
	kHFSBogusExtentFileID		= 15,	/* Used for exchanging extents in extents file */
	kHFSFirstUserCatalogNodeID	= 16
};

enum {
	kHFSExtentDensity	= 3,
	kHFSPlusExtentDensity	= 8
};

enum {
	kBTLeafNode	= -1,
	kBTIndexNode	= 0,
	kBTHeaderNode	= 1,
	kBTMapNode	= 2
};

enum {
	kBTBadCloseMask		 = 0x00000001,	/* reserved */
	kBTBigKeysMask		 = 0x00000002,	/* key length field is 16 bits */
	kBTVariableIndexKeysMask = 0x00000004	/* keys in index nodes are variable length */
};

enum {
  kClipboardIcon                = 'CLIP',
  kClippingUnknownTypeIcon      = 'clpu',
  kClippingPictureTypeIcon      = 'clpp',
  kClippingTextTypeIcon         = 'clpt',
  kClippingSoundTypeIcon        = 'clps',
  kDesktopIcon                  = 'desk',
  kFinderIcon                   = 'FNDR',
  kComputerIcon                 = 'root',
  kFontSuitcaseIcon             = 'FFIL',
  kFullTrashIcon                = 'ftrh',
  kGenericApplicationIcon       = 'APPL',
  kGenericCDROMIcon             = 'cddr',
  kGenericControlPanelIcon      = 'APPC',
  kGenericControlStripModuleIcon = 'sdev',
  kGenericComponentIcon         = 'thng',
  kGenericDeskAccessoryIcon     = 'APPD',
  kGenericDocumentIcon          = 'docu',
  kGenericEditionFileIcon       = 'edtf',
  kGenericExtensionIcon         = 'INIT',
  kGenericFileServerIcon        = 'srvr',
  kGenericFontIcon              = 'ffil',
  kGenericFontScalerIcon        = 'sclr',
  kGenericFloppyIcon            = 'flpy',
  kGenericHardDiskIcon          = 'hdsk',
  kGenericIDiskIcon             = 'idsk',
  kGenericRemovableMediaIcon    = 'rmov',
  kGenericMoverObjectIcon       = 'movr',
  kGenericPCCardIcon            = 'pcmc',
  kGenericPreferencesIcon       = 'pref',
  kGenericQueryDocumentIcon     = 'qery',
  kGenericRAMDiskIcon           = 'ramd',
  kGenericSharedLibaryIcon      = 'shlb',
  kGenericStationeryIcon        = 'sdoc',
  kGenericSuitcaseIcon          = 'suit',
  kGenericURLIcon               = 'gurl',
  kGenericWORMIcon              = 'worm',
  kInternationalResourcesIcon   = 'ifil',
  kKeyboardLayoutIcon           = 'kfil',
  kSoundFileIcon                = 'sfil',
  kSystemSuitcaseIcon           = 'zsys',
  kTrashIcon                    = 'trsh',
  kTrueTypeFontIcon             = 'tfil',
  kTrueTypeFlatFontIcon         = 'sfnt',
  kTrueTypeMultiFlatFontIcon    = 'ttcf',
  kUserIDiskIcon                = 'udsk',
  kUnknownFSObjectIcon          = 'unfs',
  kInternationResourcesIcon     = kInternationalResourcesIcon /* old name*/
};

enum {
  kGenericFolderIcon            = 'fldr',
  kDropFolderIcon               = 'dbox',
  kMountedFolderIcon            = 'mntd',
  kOpenFolderIcon               = 'ofld',
  kOwnedFolderIcon              = 'ownd',
  kPrivateFolderIcon            = 'prvf',
  kSharedFolderIcon             = 'shfl'
};

struct HFSExtentKey {
	u_int8_t 	keyLength;	/* length of key, excluding this field */
	u_int8_t 	forkType;	/* 0 = data fork, FF = resource fork */
	u_int32_t 	fileID;		/* file ID */
	u_int16_t 	startBlock;	/* first file allocation block number in this extent */
} __attribute__((aligned(2), packed));
typedef struct HFSExtentKey HFSExtentKey;

struct HFSPlusExtentKey {
	u_int16_t 	keyLength;		/* length of key, excluding this field */
	u_int8_t 	forkType;		/* 0 = data fork, FF = resource fork */
	u_int8_t 	pad;			/* make the other fields align on 32-bit boundary */
	u_int32_t 	fileID;			/* file ID */
	u_int32_t 	startBlock;		/* first file allocation block number in this extent */
} __attribute__((aligned(2), packed));
typedef struct HFSPlusExtentKey HFSPlusExtentKey;

struct HFSPlusCatalogKey {
	u_int16_t 		keyLength;	/* key length (in bytes) */
	u_int32_t 		parentID;	/* parent folder ID */
	HFSUniStr255 		nodeName;	/* catalog node name */
} __attribute__((aligned(2), packed));
typedef struct HFSPlusCatalogKey HFSPlusCatalogKey;

enum {
	kHFSPlusExtentKeyMaximumLength = sizeof(HFSPlusExtentKey) - sizeof(u_int16_t),
	kHFSExtentKeyMaximumLength	= sizeof(HFSExtentKey) - sizeof(u_int8_t),
	kHFSPlusCatalogKeyMaximumLength = sizeof(HFSPlusCatalogKey) - sizeof(u_int16_t),
	kHFSPlusCatalogKeyMinimumLength = kHFSPlusCatalogKeyMaximumLength - sizeof(HFSUniStr255) + sizeof(u_int16_t),
	kHFSCatalogKeyMaximumLength	= sizeof(HFSCatalogKey) - sizeof(u_int8_t),
	kHFSCatalogKeyMinimumLength	= kHFSCatalogKeyMaximumLength - (kHFSMaxFileNameChars + 1) + sizeof(u_int8_t),
	kHFSPlusCatalogMinNodeSize	= 4096,
	kHFSPlusExtentMinNodeSize	= 512,
	kHFSPlusAttrMinNodeSize		= 4096
};

enum {
  vLckdErr                      = -46,  /*volume is locked*/
  fBsyErr                       = -47,  /*File is busy (delete)*/
  dupFNErr                      = -48,  /*duplicate filename (rename)*/
  opWrErr                       = -49,  /*file already open with with write permission*/
  rfNumErr                      = -51,  /*refnum error*/
  gfpErr                        = -52,  /*get file position error*/
  volOffLinErr                  = -53,  /*volume not on line error (was Ejected)*/
  permErr                       = -54,  /*permissions error (on file open)*/
  volOnLinErr                   = -55,  /*drive volume already on-line at MountVol*/
  nsDrvErr                      = -56,  /*no such drive (tried to mount a bad drive num)*/
  noMacDskErr                   = -57,  /*not a mac diskette (sig bytes are wrong)*/
  extFSErr                      = -58,  /*volume in question belongs to an external fs*/
  fsRnErr                       = -59,  /*file system internal error:during rename the old entry was deleted but could not be restored.*/
  badMDBErr                     = -60,  /*bad master directory block*/
  wrPermErr                     = -61,  /*write permissions error*/
  dirNFErr                      = -120, /*Directory not found*/
  tmwdoErr                      = -121, /*No free WDCB available*/
  badMovErr                     = -122, /*Move into offspring error*/
  wrgVolTypErr                  = -123, /*Wrong volume type error [operation not supported for MFS]*/
  volGoneErr                    = -124  /*Server volume has been disconnected.*/
};

enum {
	kTextEncodingMacRoman         = 0,
};


struct HFSMasterDirectoryBlock {
	u_int16_t 		drSigWord;	/* == kHFSSigWord */
	u_int32_t 		drCrDate;	/* date and time of volume creation */
	u_int32_t 		drLsMod;	/* date and time of last modification */
	u_int16_t 		drAtrb;		/* volume attributes */
	u_int16_t 		drNmFls;	/* number of files in root folder */
	u_int16_t 		drVBMSt;	/* first block of volume bitmap */
	u_int16_t 		drAllocPtr;	/* start of next allocation search */
	u_int16_t 		drNmAlBlks;	/* number of allocation blocks in volume */
	u_int32_t 		drAlBlkSiz;	/* size (in bytes) of allocation blocks */
	u_int32_t 		drClpSiz;	/* default clump size */
	u_int16_t 		drAlBlSt;	/* first allocation block in volume */
	u_int32_t 		drNxtCNID;	/* next unused catalog node ID */
	u_int16_t 		drFreeBks;	/* number of unused allocation blocks */
	u_int8_t 		drVN[kHFSMaxVolumeNameChars + 1];  /* volume name */
	u_int32_t 		drVolBkUp;	/* date and time of last backup */
	u_int16_t 		drVSeqNum;	/* volume backup sequence number */
	u_int32_t 		drWrCnt;	/* volume write count */
	u_int32_t 		drXTClpSiz;	/* clump size for extents overflow file */
	u_int32_t 		drCTClpSiz;	/* clump size for catalog file */
	u_int16_t 		drNmRtDirs;	/* number of directories in root folder */
	u_int32_t 		drFilCnt;	/* number of files in volume */
	u_int32_t 		drDirCnt;	/* number of directories in volume */
	u_int32_t 		drFndrInfo[8];	/* information used by the Finder */
	u_int16_t 		drEmbedSigWord;	/* embedded volume signature (formerly drVCSize) */
	HFSExtentDescriptor	drEmbedExtent;	/* embedded volume location and size (formerly drVBMCSize and drCtlCSize) */
	u_int32_t		drXTFlSize;	/* size of extents overflow file */
	HFSExtentRecord		drXTExtRec;	/* extent record for extents overflow file */
	u_int32_t 		drCTFlSize;	/* size of catalog file */
	HFSExtentRecord 	drCTExtRec;	/* extent record for catalog file */
} __attribute__((aligned(2), packed));
typedef struct HFSMasterDirectoryBlock	HFSMasterDirectoryBlock;

enum {
	kHFSSigWord		= 0x4244,
	kHFSPlusSigWord		= 0x482B
};

enum {
  kFirstMagicBusyFiletype       = 'bzy ',
  kLastMagicBusyFiletype        = 'bzy?'
};

struct FileInfo {
  OSType              fileType;               /* The type of the file */
  OSType              fileCreator;            /* The file's creator */
  UInt16              finderFlags;            /* ex: kHasBundle, kIsInvisible... */
  Point               location;               /* File's location in the folder */
											  /* If set to {0, 0}, the Finder will place the item automatically */
  UInt16              reservedField;          /* (set to 0) */
};
typedef struct FileInfo                 FileInfo;

struct HFSPlusCatalogThread {
	int16_t 	recordType;		/* == kHFSPlusFolderThreadRecord or kHFSPlusFileThreadRecord */
	int16_t 	reserved;		/* reserved - initialized as zero */
	u_int32_t 	parentID;		/* parent ID for this catalog node */
	HFSUniStr255 	nodeName;		/* name of this catalog node (variable length) */
} __attribute__((aligned(2), packed));
typedef struct HFSPlusCatalogThread HFSPlusCatalogThread;

struct HFSCatalogThread {
	int16_t 	recordType;		/* == kHFSFolderThreadRecord or kHFSFileThreadRecord */
	int32_t 	reserved[2];		/* reserved - initialized as zero */
	u_int32_t 	parentID;		/* parent ID for this catalog node */
	u_int8_t 	nodeName[kHFSMaxFileNameChars + 1]; /* name of this catalog node */
} __attribute__((aligned(2), packed));
typedef struct HFSCatalogThread HFSCatalogThread;

struct HFSPlusVolumeHeader {
	u_int16_t 	signature;		/* == kHFSPlusSigWord */
	u_int16_t 	version;		/* == kHFSPlusVersion */
	u_int32_t 	attributes;		/* volume attributes */
	u_int32_t 	lastMountedVersion;	/* implementation version which last mounted volume */
	u_int32_t 	journalInfoBlock;	/* block addr of journal info (if volume is journaled, zero otherwise) */

	u_int32_t 	createDate;		/* date and time of volume creation */
	u_int32_t 	modifyDate;		/* date and time of last modification */
	u_int32_t 	backupDate;		/* date and time of last backup */
	u_int32_t 	checkedDate;		/* date and time of last disk check */

	u_int32_t 	fileCount;		/* number of files in volume */
	u_int32_t 	folderCount;		/* number of directories in volume */

	u_int32_t 	blockSize;		/* size (in bytes) of allocation blocks */
	u_int32_t 	totalBlocks;		/* number of allocation blocks in volume (includes this header and VBM*/
	u_int32_t 	freeBlocks;		/* number of unused allocation blocks */

	u_int32_t 	nextAllocation;		/* start of next allocation search */
	u_int32_t 	rsrcClumpSize;		/* default resource fork clump size */
	u_int32_t 	dataClumpSize;		/* default data fork clump size */
	u_int32_t 	nextCatalogID;		/* next unused catalog node ID */

	u_int32_t 	writeCount;		/* volume write count */
	u_int64_t 	encodingsBitmap;	/* which encodings have been use  on this volume */

	u_int8_t 	finderInfo[32];		/* information used by the Finder */

	HFSPlusForkData	 allocationFile;	/* allocation bitmap file */
	HFSPlusForkData  extentsFile;		/* extents B-tree file */
	HFSPlusForkData  catalogFile;		/* catalog B-tree file */
	HFSPlusForkData  attributesFile;	/* extended attributes B-tree file */
	HFSPlusForkData	 startupFile;		/* boot file (secondary loader) */
} __attribute__((aligned(2), packed));
typedef struct HFSPlusVolumeHeader HFSPlusVolumeHeader;

struct BTNodeDescriptor {
	u_int32_t	fLink;			/* next node at this level*/
	u_int32_t 	bLink;			/* previous node at this level*/
	int8_t 		kind;			/* kind of node (leaf, index, header, map)*/
	u_int8_t 	height;			/* zero for header, map; child is one more than parent*/
	u_int16_t 	numRecords;		/* number of records in this node*/
	u_int16_t 	reserved;		/* reserved - initialized as zero */
} __attribute__((aligned(2), packed));
typedef struct BTNodeDescriptor BTNodeDescriptor;


struct BTHeaderRec {
	u_int16_t	treeDepth;		/* maximum height (usually leaf nodes) */
	u_int32_t 	rootNode;		/* node number of root node */
	u_int32_t 	leafRecords;		/* number of leaf records in all leaf nodes */
	u_int32_t 	firstLeafNode;		/* node number of first leaf node */
	u_int32_t 	lastLeafNode;		/* node number of last leaf node */
	u_int16_t 	nodeSize;		/* size of a node, in bytes */
	u_int16_t 	maxKeyLength;		/* reserved */
	u_int32_t 	totalNodes;		/* total number of nodes in tree */
	u_int32_t 	freeNodes;		/* number of unused (free) nodes in tree */
	u_int16_t 	reserved1;		/* unused */
	u_int32_t 	clumpSize;		/* reserved */
	u_int8_t 	btreeType;		/* reserved */
	u_int8_t 	keyCompareType;		/* Key string Comparison Type */
	u_int32_t 	attributes;		/* persistent attributes about the tree */
	u_int32_t 	reserved3[16];		/* reserved */
} __attribute__((aligned(2), packed));
typedef struct BTHeaderRec BTHeaderRec;

struct FInfo {
  OSType              fdType;                 /* The type of the file */
  OSType              fdCreator;              /* The file's creator */
  UInt16              fdFlags;                /* Flags ex. kHasBundle, kIsInvisible, etc. */
  Point               fdLocation;             /* File's location in folder. */
											  /* If set to {0, 0}, the Finder will place the item automatically */
  SInt16              fdFldr;                 /* Reserved (set to 0) */
};
typedef struct FInfo                    FInfo;

struct FXInfo {
  SInt16              fdIconID;               /* Reserved (set to 0) */
  SInt16              fdReserved[3];          /* Reserved (set to 0) */
  SInt8               fdScript;               /* Extended flags. Script code if high-bit is set */
  SInt8               fdXFlags;               /* Extended flags */
  SInt16              fdComment;              /* Reserved (set to 0). Comment ID if high-bit is clear */
  SInt32              fdPutAway;              /* Put away folder ID */
};
typedef struct FXInfo                   FXInfo;

struct DInfo {
  Rect                frRect;                 /* Folder's window bounds */
  UInt16              frFlags;                /* Flags ex. kIsInvisible, kNameLocked, etc.*/
  Point               frLocation;             /* Folder's location in parent folder */
											  /* If set to {0, 0}, the Finder will place the item automatically */
  SInt16              frView;                 /* Reserved (set to 0) */
};
typedef struct DInfo                    DInfo;

struct DXInfo {
  Point               frScroll;               /* Scroll position */
  SInt32              frOpenChain;            /* Reserved (set to 0) */
  SInt8               frScript;               /* Extended flags. Script code if high-bit is set */
  SInt8               frXFlags;               /* Extended flags */
  SInt16              frComment;              /* Reserved (set to 0). Comment ID if high-bit is clear */
  SInt32              frPutAway;              /* Put away folder ID */
};
typedef struct DXInfo                   DXInfo;

enum {
  kIsOnDesk                     = 0x0001, /* Files and folders (System 6) */
  kColor                        = 0x000E, /* Files and folders */
										/* bit 0x0020 was kRequireSwitchLaunch, but is now reserved for future use*/
  kIsShared                     = 0x0040, /* Files only (Applications only) */
										/* If clear, the application needs to write to */
										/* its resource fork, and therefore cannot be */
										/* shared on a server */
  kHasNoINITs                   = 0x0080, /* Files only (Extensions/Control Panels only) */
										/* This file contains no INIT resource */
  kHasBeenInited                = 0x0100, /* Files only */
										/* Clear if the file contains desktop database */
										/* resources ('BNDL', 'FREF', 'open', 'kind'...) */
										/* that have not been added yet. Set only by the Finder */
										/* Reserved for folders - make sure this bit is cleared for folders */
										/* bit 0x0200 was the letter bit for AOCE, but is now reserved for future use */
  kHasCustomIcon                = 0x0400, /* Files and folders */
  kIsStationery                 = 0x0800, /* Files only */
  kNameLocked                   = 0x1000, /* Files and folders */
  kHasBundle                    = 0x2000, /* Files and folders */
										/* Indicates that a file has a BNDL resource */
										/* Indicates that a folder is displayed as a package */
  kIsInvisible                  = 0x4000, /* Files and folders */
  kIsAlias                      = 0x8000 /* Files only */
};

enum {
	kHFSFileLockedMask	= 0x0001,
};

enum {
	/* HFS Catalog Records */
	kHFSFolderRecord		= 0x0100,	/* Folder record */
	kHFSFileRecord			= 0x0200,	/* File record */
	kHFSFolderThreadRecord		= 0x0300,	/* Folder thread record */
	kHFSFileThreadRecord		= 0x0400,	/* File thread record */

	/* HFS Plus Catalog Records */
	kHFSPlusFolderRecord		= 1,		/* Folder record */
	kHFSPlusFileRecord		= 2,		/* File record */
	kHFSPlusFolderThreadRecord	= 3,		/* Folder thread record */
	kHFSPlusFileThreadRecord	= 4		/* File thread record */
};

struct FndrExtendedFileInfo {
	u_int32_t document_id;
	u_int32_t date_added;
	u_int16_t extended_flags;
	u_int16_t reserved2;
	u_int32_t write_gen_counter;
} __attribute__((aligned(2), packed));

enum {
  kExtendedFlagsAreInvalid      = 0x8000, /* If set the other extended flags are ignored */
  kExtendedFlagHasCustomBadge   = 0x0100, /* Set if the file or folder has a badge resource */
  kExtendedFlagObjectIsBusy     = 0x0080, /* Set if the object is marked as busy/incomplete */
  kExtendedFlagHasRoutingInfo   = 0x0004 /* Set if the file contains routing info resource */
};
