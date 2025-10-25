//
//  ImpDehydratedItem.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import "ImpDehydratedItem.h"

#import <os/overflow.h>

#import "ImpTextEncodingConverter.h"
#import "ImpByteOrder.h"
#import "ImpPrintf.h"

#import "ImpSourceVolume.h"
#import "ImpHFSSourceVolume.h"
#import "ImpHFSPlusSourceVolume.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
//#import "ImpDehydratedResourceFork.h"

typedef NS_ENUM(u_int64_t, ImpVolumeSizeThreshold) {
	//Rough estimates just for icon selection purposes.
	floppyMaxSize = 2 * 1048576,
	cdMaxSize = 700 * 1048576,
	dvdMaxSize = 10ULL * 1048576ULL * 1024ULL,
};

@interface ImpDehydratedItem ()

- (bool) rehydrateFileAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError;

@property(nullable, nonatomic, readwrite, copy) NSArray <ImpDehydratedItem *> *children;

@end

static NSTimeInterval hfsEpochTISRD = -3061152000.0; //1904-01-01T00:00:00Z timeIntervalSinceReferenceDate

@implementation ImpDehydratedItem
{
	NSArray <NSString *> *_cachedPath;
	NSMutableArray <ImpDehydratedItem *> *_children;
	ImpTextEncodingConverter *_tec;
//	ImpDehydratedResourceFork *_resourceFork;
	NSData *_vers1ResourceData;
	bool _hasCheckedForVers1Resource;
	bool _isHFSPlus;
}

- (instancetype _Nonnull) initWithSourceVolume:(ImpSourceVolume *_Nonnull const)hfsVol catalogNodeID:(HFSCatalogNodeID const)cnid {
	if ((self = [super init])) {
		self.sourceVolume = hfsVol;
		self.catalogNodeID = cnid;

		_tec = hfsVol.textEncodingConverter;
	}
	return self;
}

- (instancetype _Nonnull) initWithHFSSourceVolume:(ImpHFSSourceVolume *_Nonnull const)srcVol
	catalogNodeID:(HFSCatalogNodeID const)cnid
	key:(struct HFSCatalogKey const *_Nonnull const)key
	fileRecord:(struct HFSCatalogFile const *_Nonnull const)fileRec
{
	if ((self = [self initWithSourceVolume:srcVol catalogNodeID:cnid])) {
		size_t const keyLength = L(key->keyLength) + sizeof(key->keyLength);
		self.hfsCatalogKeyData = [NSData dataWithBytesNoCopy:(void *)key length:keyLength freeWhenDone:false];
		self.hfsFileCatalogRecordData = [NSData dataWithBytesNoCopy:(void *)fileRec length:sizeof(*fileRec) freeWhenDone:false];

		self.type = ImpDehydratedItemTypeFile;
		_isHFSPlus = false;
	}
	return self;
}

- (instancetype _Nonnull) initWithHFSSourceVolume:(ImpHFSSourceVolume *_Nonnull const)srcVol
	catalogNodeID:(HFSCatalogNodeID const)cnid
	key:(struct HFSCatalogKey const *_Nonnull const)key
	folderRecord:(struct HFSCatalogFolder const *_Nonnull const)folderRec
{
	if ((self = [self initWithSourceVolume:srcVol catalogNodeID:cnid])) {
		size_t const keyLength = L(key->keyLength) + sizeof(key->keyLength);
		self.hfsCatalogKeyData = [NSData dataWithBytesNoCopy:(void *)key length:keyLength freeWhenDone:false];
		self.hfsFolderCatalogRecordData = [NSData dataWithBytesNoCopy:(void *)folderRec length:sizeof(*folderRec) freeWhenDone:false];

		_parentFolderID = L(key->parentID);
		_type = _parentFolderID == kHFSRootParentID ? ImpDehydratedItemTypeVolume : ImpDehydratedItemTypeFolder;
		_isHFSPlus = false;
	}
	return self;
}

///Create a dehydrated item object that references a given HFS+ catalog. The initializer will populate the object's properties with the catalog's data for the given catalog node ID.
- (instancetype _Nonnull) initWithHFSPlusSourceVolume:(ImpHFSPlusSourceVolume *_Nonnull const)srcVol
	catalogNodeID:(HFSCatalogNodeID const)cnid
	key:(struct HFSPlusCatalogKey const *_Nonnull const)key
	fileRecord:(struct HFSPlusCatalogFile const *_Nonnull const)fileRec
{
	if ((self = [self initWithSourceVolume:srcVol catalogNodeID:cnid])) {
		size_t const keyLength = L(key->keyLength) + sizeof(key->keyLength);
		self.hfsCatalogKeyData = [NSData dataWithBytesNoCopy:(void *)key length:keyLength freeWhenDone:false];
		self.hfsFileCatalogRecordData = [NSData dataWithBytesNoCopy:(void *)fileRec length:sizeof(*fileRec) freeWhenDone:false];

		self.type = ImpDehydratedItemTypeFile;
		_isHFSPlus = true;
	}
	return self;
}

- (instancetype _Nonnull) initWithHFSPlusSourceVolume:(ImpHFSPlusSourceVolume *_Nonnull const)srcVol
	catalogNodeID:(HFSCatalogNodeID const)cnid
	key:(struct HFSPlusCatalogKey const *_Nonnull const)key
	folderRecord:(struct HFSPlusCatalogFolder const *_Nonnull const)folderRec
{
	if ((self = [self initWithSourceVolume:srcVol catalogNodeID:cnid])) {
		size_t keyLength = L(key->keyLength) + sizeof(key->keyLength);
		keyLength += keyLength % 1;
		self.hfsCatalogKeyData = [NSData dataWithBytesNoCopy:(void *)key length:keyLength freeWhenDone:false];
		self.hfsFolderCatalogRecordData = [NSData dataWithBytesNoCopy:(void *)folderRec length:sizeof(*folderRec) freeWhenDone:false];

		_parentFolderID = L(key->parentID);
		_type = _parentFolderID == kHFSRootParentID ? ImpDehydratedItemTypeVolume : ImpDehydratedItemTypeFolder;
		_isHFSPlus = true;
	}
	return self;
}

- (NSUInteger) hash {
	NSUInteger hash = self.name.hash << 5;
	hash |= (self.path.count & 0xf) << 1;
	hash |= self.isDirectory;
	return hash;
}
- (BOOL) isEqual:(id)object {
	if (self == object)
		return true;
	if (! [object isKindOfClass:[ImpDehydratedItem class]])
		return false;
	return [self.path isEqualToArray:((ImpDehydratedItem *)object).path];
}

- (bool) isDirectory {
	return self.type != ImpDehydratedItemTypeFile;
}

- (HFSCatalogNodeID) parentFolderID {
	if (_isHFSPlus) {
		struct HFSPlusCatalogKey const *_Nonnull const catalogKey = (struct HFSPlusCatalogKey const *_Nonnull const)(self.hfsCatalogKeyData.bytes);
		return L(catalogKey->parentID);
	} else {
		struct HFSCatalogKey const *_Nonnull const catalogKey = (struct HFSCatalogKey const *_Nonnull const)(self.hfsCatalogKeyData.bytes);
		return L(catalogKey->parentID);
	}
}

- (NSString *_Nonnull const) name {
	if (_isHFSPlus) {
		struct HFSPlusCatalogKey const *_Nonnull const catalogKey = (struct HFSPlusCatalogKey const *_Nonnull const)(self.hfsCatalogKeyData.bytes);
		return [_tec stringFromHFSUniStr255:&(catalogKey->nodeName)];
	} else {
		struct HFSCatalogKey const *_Nonnull const catalogKey = (struct HFSCatalogKey const *_Nonnull const)(self.hfsCatalogKeyData.bytes);
		return [_tec stringForPascalString:catalogKey->nodeName];
	}
}

- (NSDate *_Nonnull const) creationDate {
	if (_isHFSPlus) {
		if (self.isDirectory) {
			struct HFSPlusCatalogFolder const *_Nonnull const folderRec = (struct HFSPlusCatalogFolder const *)(self.hfsFolderCatalogRecordData.bytes);
			return [self dateForHFSDate:L(folderRec->createDate)];
		} else {
			struct HFSPlusCatalogFile const *_Nonnull const fileRec = (struct HFSPlusCatalogFile const *)(self.hfsFileCatalogRecordData.bytes);
			return [self dateForHFSDate:L(fileRec->createDate)];
		}
	} else {
		if (self.isDirectory) {
			struct HFSCatalogFolder const *_Nonnull const folderRec = (struct HFSCatalogFolder const *)(self.hfsFolderCatalogRecordData.bytes);
			return [self dateForHFSDate:L(folderRec->createDate)];
		} else {
			struct HFSCatalogFile const *_Nonnull const fileRec = (struct HFSCatalogFile const *)(self.hfsFileCatalogRecordData.bytes);
			return [self dateForHFSDate:L(fileRec->createDate)];
		}
	}
}

- (NSDate *_Nonnull const) modificationDate {
	if (_isHFSPlus) {
		if (self.isDirectory) {
			struct HFSPlusCatalogFolder const *_Nonnull const folderRec = (struct HFSPlusCatalogFolder const *)(self.hfsFolderCatalogRecordData.bytes);
			return [self dateForHFSDate:L(folderRec->contentModDate)];
		} else {
			struct HFSPlusCatalogFile const *_Nonnull const fileRec = (struct HFSPlusCatalogFile const *)(self.hfsFileCatalogRecordData.bytes);
			return [self dateForHFSDate:L(fileRec->contentModDate)];
		}
	} else {
		if (self.isDirectory) {
			struct HFSCatalogFolder const *_Nonnull const folderRec = (struct HFSCatalogFolder const *)(self.hfsFolderCatalogRecordData.bytes);
			return [self dateForHFSDate:L(folderRec->modifyDate)];
		} else {
			struct HFSCatalogFile const *_Nonnull const fileRec = (struct HFSCatalogFile const *)(self.hfsFileCatalogRecordData.bytes);
			return [self dateForHFSDate:L(fileRec->modifyDate)];
		}
	}
}

- (OSType) fileTypeCode {
	if (_isHFSPlus) {
		if (self.isDirectory) {
			return 0;
		} else {
			struct HFSPlusCatalogFile const *_Nonnull const fileRec = (struct HFSPlusCatalogFile const *)(self.hfsFileCatalogRecordData.bytes);
			return L(fileRec->userInfo.fdType);
		}
	} else {
		if (self.isDirectory) {
			return 0;
		} else {
			struct HFSCatalogFile const *_Nonnull const fileRec = (struct HFSCatalogFile const *)(self.hfsFileCatalogRecordData.bytes);
			return L(fileRec->userInfo.fdType);
		}
	}
}
- (OSType) creatorCode {
	if (_isHFSPlus) {
		if (self.isDirectory) {
			return 0;
		} else {
			struct HFSPlusCatalogFile const *_Nonnull const fileRec = (struct HFSPlusCatalogFile const *)(self.hfsFileCatalogRecordData.bytes);
			return L(fileRec->userInfo.fdCreator);
		}
	} else {
		if (self.isDirectory) {
			return 0;
		} else {
			struct HFSCatalogFile const *_Nonnull const fileRec = (struct HFSCatalogFile const *)(self.hfsFileCatalogRecordData.bytes);
			return L(fileRec->userInfo.fdCreator);
		}
	}
}

///Returns the contents of 'vers' resource ID 1, if it exists, or else nil.
//- (NSData *_Nullable const) applicationVersionResource {
//	if (! _hasCheckedForVers1Resource) {
//		ImpDehydratedResourceFork *_Nullable const resourceFork = [[ImpDehydratedResourceFork alloc] initWithItem:self];
//		NSData *_Nullable const resourceData = [resourceFork resourceOfType:'vers' ID:1];
//
//		enum {
//			///We can't use sizeof(VersRec) because MacTypes.h defines the VersRec structure as ending with two Str255s. The problem with that is that they aren't unconditionally stored in 256 bytes each; the strings are packed, allocated only as much space as needed to hold the string.
//			///So the *minimum* size of the structure is its numeric components plus two empty Pascal strings (length bytes of value zero). That's the size to use to validate that this might be a VersRec.
//			///Further validation can be done by checking that the length byte of the shortVersion string does not indicate more string than is actually present in the stored resource. (This could reject 'vers' resources that were correctly read, but hold corrupted VersRec data, either because it was corrupted before addition to the resource fork or because the resource map is itself corrupted. That is to say, it could be that either the string's length or the resource's length is genuinely wrong.)
//			ImpMinimumVersRecSize = sizeof(NumVersion) + sizeof(SInt16) + sizeof(unsigned char) + sizeof(unsigned char),
//			///The size of the portion of the VersRec structure that precedes the two strings. This can be added to the shortVersion length byte to validate that that length fits within the resource data we have retrieved.
//			ImpVersRecPreStringsSize = sizeof(NumVersion) + sizeof(SInt16),
//		};
//
//		if (resourceData != nil && resourceData.length >= ImpMinimumVersRecSize) {
//			_vers1ResourceData = resourceData;
//		}
//
//		_hasCheckedForVers1Resource = true;
//	}
//	return _vers1ResourceData;
//}

- (u_int32_t) hfsDateForDate:(NSDate *_Nonnull const)dateToConvert {
	return (u_int32_t)(dateToConvert.timeIntervalSinceReferenceDate - hfsEpochTISRD);
}
- (NSDate *_Nonnull const) dateForHFSDate:(u_int32_t const)hfsDate {
	return [NSDate dateWithTimeIntervalSinceReferenceDate:hfsDate + hfsEpochTISRD];
}

- (u_int64_t) dataForkLogicalLength {
	if (_isHFSPlus) {
		struct HFSPlusCatalogFile const *_Nonnull const fileRec = self.hfsFileCatalogRecordData.bytes;
		return L(fileRec->dataFork.logicalSize);
	} else {
		struct HFSCatalogFile const *_Nonnull const fileRec = self.hfsFileCatalogRecordData.bytes;
		return L(fileRec->dataLogicalSize);
	}
}
- (u_int64_t) resourceForkLogicalLength {
	if (_isHFSPlus) {
		struct HFSPlusCatalogFile const *_Nonnull const fileRec = self.hfsFileCatalogRecordData.bytes;
		return L(fileRec->resourceFork.logicalSize);
	} else {
		struct HFSCatalogFile const *_Nonnull const fileRec = self.hfsFileCatalogRecordData.bytes;
		return L(fileRec->rsrcLogicalSize);
	}
}

///Search the catalog for parent items until reaching the volume root, then return the path so constructed.
- (NSArray <NSString *> *_Nonnull const) path {
	if (_cachedPath == nil) {
		NSMutableArray <NSString *> *_Nonnull const path = [NSMutableArray arrayWithCapacity:8];
		[path addObject:self.name];

		ImpBTreeFile *_Nonnull const catalog = self.sourceVolume.catalogBTree;
		NSData *_Nullable keyData = nil;
		HFSCatalogNodeID nextParentID = self.parentFolderID;
		NSData *_Nullable threadRecordData = nil;

		//Keep ascending directories until we reach kHFSRootParentID, which is the parent of the root directory.
		if (_isHFSPlus) {
			struct HFSUniStr255 emptyName = { .length = 0 };
			while (nextParentID != kHFSRootParentID && [catalog searchCatalogTreeForItemWithParentID:nextParentID unicodeName:&emptyName getRecordKeyData:&keyData threadRecordData:&threadRecordData]) {
				struct HFSPlusCatalogThread const *_Nonnull const threadPtr = threadRecordData.bytes;
				NSString *_Nonnull const name = [_tec stringFromHFSUniStr255:&(threadPtr->nodeName)];
				[path insertObject:name atIndex:0];
				nextParentID = L(threadPtr->parentID);
			}
		} else {
			while (nextParentID != kHFSRootParentID && [catalog searchCatalogTreeForItemWithParentID:nextParentID name:"\p" getRecordKeyData:&keyData threadRecordData:&threadRecordData]) {
				struct HFSCatalogThread const *_Nonnull const threadPtr = threadRecordData.bytes;
				NSString *_Nonnull const name = [_tec stringForPascalString:threadPtr->nodeName];
				[path insertObject:name atIndex:0];
				nextParentID = L(threadPtr->parentID);
			}
		}

		_cachedPath = path;
	}

	return _cachedPath;
}

- (NSData *_Nullable const) rehydrateForkContents:(ImpForkType)whichFork {
	if (self.isDirectory) {
		return nil;
	}

	ImpSourceVolume *_Nonnull const srcVolume = self.sourceVolume;
	ImpHFSSourceVolume *_Nonnull const hfsVolume = [srcVolume isKindOfClass:[ImpHFSSourceVolume class]] ? (ImpHFSSourceVolume *)srcVolume : nil;
	ImpHFSPlusSourceVolume *_Nullable const hfsPlusVolume = [srcVolume isKindOfClass:[ImpHFSPlusSourceVolume class]] ? (ImpHFSPlusSourceVolume *)srcVolume : nil;

	NSData *_Nonnull const fileRecData = self.hfsFileCatalogRecordData;
	struct HFSCatalogFile const *_Nullable const hfsFileRec = _isHFSPlus ? NULL : fileRecData.bytes;
	struct HFSPlusCatalogFile const *_Nullable const hfsPlusFileRec = _isHFSPlus ? fileRecData.bytes : NULL;

	u_int64_t logicalLength = 0;
	struct HFSExtentDescriptor const *_Nullable extents = NULL;
	struct HFSPlusExtentDescriptor const *_Nullable extentsPlus = NULL;
	switch (whichFork) {
		case ImpForkTypeData:
			if (_isHFSPlus) {
				logicalLength = L(hfsPlusFileRec->dataFork.logicalSize);
				extentsPlus = hfsPlusFileRec->dataFork.extents;
			} else {
				logicalLength = L(hfsFileRec->dataLogicalSize);
				extents = hfsFileRec->dataExtents;
			}
			break;

		case ImpForkTypeResource:
			if (_isHFSPlus) {
				logicalLength = L(hfsPlusFileRec->resourceFork.logicalSize);
				extentsPlus = hfsPlusFileRec->resourceFork.extents;
			} else {
				logicalLength = L(hfsFileRec->rsrcLogicalSize);
				extents = hfsFileRec->rsrcExtents;
			}
			break;

		default:
			return nil;
	}

	NSMutableData *_Nonnull const forkContents = [NSMutableData dataWithCapacity:logicalLength];
	bool (^_Nonnull const appendBlock)(NSData *_Nonnull const fileData, u_int64_t const logicalLengthRemaining) = ^bool(NSData *_Nonnull const fileData, u_int64_t const logicalLengthRemaining) {
		[forkContents appendData:fileData];
		return true;
	};

	//TODO: This still swallows the error on GUI clients.
	NSError *_Nullable readError = nil;

	u_int64_t totalLengthRead = 0;
	if (_isHFSPlus) {
		totalLengthRead = [hfsPlusVolume forEachExtentInFileWithID:self.catalogNodeID
			fork:whichFork
			forkLogicalLength:logicalLength
			startingWithBigExtentsRecord:extentsPlus
			readDataOrReturnError:&readError
			block:appendBlock];
	} else {
		totalLengthRead = [hfsVolume forEachExtentInFileWithID:self.catalogNodeID
			fork:whichFork
			forkLogicalLength:logicalLength
			startingWithExtentsRecord:extents
			readDataOrReturnError:&readError
			block:appendBlock];
	}

	if (totalLengthRead == logicalLength) {
		return forkContents;
	} else {
		ImpPrintf(@"Failed to read %llu bytes; got %llu bytes instead", logicalLength, totalLengthRead);
		return nil;
	}
}

- (bool) rehydrateIntoRealWorldDirectoryAtURL:(NSURL *_Nonnull const)realWorldParentURL error:(NSError *_Nullable *_Nonnull const)outError {
	return [self rehydrateAtRealWorldURL:[realWorldParentURL URLByAppendingPathComponent:self.name isDirectory:self.isDirectory] error:outError];
}
- (bool) rehydrateAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError {
	NSError *_Nullable reachabilityCheckError = nil;
	bool const alreadyExists = [realWorldURL checkResourceIsReachableAndReturnError:&reachabilityCheckError];
	if (alreadyExists) {
		NSDictionary <NSString *, NSObject *> *_Nonnull const userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:NSLocalizedString(@"Output file %@ already exists; not overwriting", /*comment*/ @""), realWorldURL.path], NSLocalizedDescriptionKey,
			reachabilityCheckError, NSUnderlyingErrorKey,
			nil];
		NSError *_Nonnull const alreadyExistsError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError userInfo:userInfo];
		if (outError != NULL) {
			*outError = alreadyExistsError;
		}
		return false;
	}


    return [self rehydrateFileAtRealWorldURL:realWorldURL error:outError];
}

- (bool) rehydrateFileAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError {
	ImpSourceVolume *_Nullable const srcVolume = self.sourceVolume;
	NSAssert(srcVolume != nil, @"Can't rehydrate a file from no volume. This is likely an internal inconsistency error and therefore a bug.");

	ImpHFSSourceVolume *_Nonnull const hfsVolume = [srcVolume isKindOfClass:[ImpHFSSourceVolume class]] ? (ImpHFSSourceVolume *)srcVolume : nil;

	struct HFSCatalogFile const *_Nonnull const fileRec = (struct HFSCatalogFile const *_Nonnull const)self.hfsFileCatalogRecordData.bytes;
	struct HFSPlusCatalogFile const *_Nonnull const fileRecPlus = (struct HFSPlusCatalogFile const *_Nonnull const)self.hfsFileCatalogRecordData.bytes;

	//TODO: This implementation will overwrite the destination file if it already exists. The client should probably check for that and prompt for confirmation…

	off_t const dataForkSize = _isHFSPlus ? L(fileRecPlus->dataFork.logicalSize) : L(fileRec->dataLogicalSize);

	//Realistically, we have to use the File Manager.
	//The alternative is using NSURL and writing to resource forks as realWorldURL/..namedFork/rsrc. This doesn't work on APFS, for reasons unknown, and still wouldn't enable us to rehydrate certain metadata, such as the Locked checkbox.
	//So we're using deprecated API for want of an alternative. That means both methods that use such API need to silence the deprecated-API warnings.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

	bool (^_Nonnull const writeDataForkBlock)(NSData *_Nonnull const fileData, u_int64_t const logicalLength) = ^bool(NSData *_Nonnull const fileData, u_int64_t const logicalLength)
	{
        NSData *trimmedData = [NSData dataWithBytes:fileData.bytes length:dataForkSize];
        [trimmedData writeToURL:realWorldURL atomically:YES];

		return YES;
	};

    [hfsVolume forEachExtentInFileWithID:self.catalogNodeID
                                    fork:ImpForkTypeData
                       forkLogicalLength:dataForkSize
               startingWithExtentsRecord:fileRec->dataExtents
                   readDataOrReturnError:outError
                                   block:writeDataForkBlock];

#pragma clang diagnostic pop

    return YES;
}

#pragma mark Directory trees

///Returns a string that represents this item when printed to the console.
- (NSString *_Nonnull) iconEmojiString {
	ImpSourceVolume *_Nullable const volume = self.sourceVolume;

	switch (self.type) {
		case ImpDehydratedItemTypeFile:
			return @"📄";
		case ImpDehydratedItemTypeFolder:
			return @"📁";
		case ImpDehydratedItemTypeVolume:
			if (volume != nil) {
				if (volume.lengthInBytes <= floppyMaxSize) {
					return @"💾";
				} else if (volume.lengthInBytes <= cdMaxSize) {
					return @"💿";
				} else if (volume.lengthInBytes <= dvdMaxSize) {
					return @"📀";
				} else {
					return @"🗄";
				}
			}
	}
	return @"❓";
}

- (void) _walkBreadthFirstAtDepth:(NSUInteger)depth block:(void (^_Nonnull const)(NSUInteger const depth, ImpDehydratedItem *_Nullable const item))block
{
	block(depth, self);
	++depth;

	NSMutableArray <ImpDehydratedItem *> *_Nonnull const subfolders = [NSMutableArray arrayWithCapacity:self.countOfChildren];
	for (ImpDehydratedItem *_Nonnull const item in self.children) {
		block(depth, item);
		if (item.isDirectory) {
			[subfolders addObject:item];
		}
	}

	block(depth, nil);

	for (ImpDehydratedItem *_Nonnull const item in subfolders) {
		[item _walkBreadthFirstAtDepth:depth block:block];
	}
}

///Call the block for each item in the tree. Calls the block with nil for the item at the end of each directory.
- (void) walkBreadthFirst:(void (^_Nonnull const)(NSUInteger const depth, ImpDehydratedItem *_Nullable const item))block {
	[self _walkBreadthFirstAtDepth:0 block:block];
}

+ (instancetype _Nonnull) rootDirectoryOfHFSVolume:(ImpSourceVolume *_Nonnull const)srcVol {
	ImpBTreeFile *_Nonnull const catalog = srcVol.catalogBTree;

	ImpHFSSourceVolume *_Nonnull const hfsVolume = [srcVol isKindOfClass:[ImpHFSSourceVolume class]] ? (ImpHFSSourceVolume *)srcVol : nil;
	ImpHFSPlusSourceVolume *_Nullable const hfsPlusVolume = [srcVol isKindOfClass:[ImpHFSPlusSourceVolume class]] ? (ImpHFSPlusSourceVolume *)srcVol : nil;

	NSUInteger const totalNumItems = srcVol.numberOfFiles + srcVol.numberOfFolders;
	NSMutableDictionary <NSNumber *, ImpDehydratedItem *> *_Nonnull const dehydratedFolders = [NSMutableDictionary dictionaryWithCapacity:srcVol.numberOfFolders];
	//This is totally a wild guess of a heuristic.
	NSMutableArray <ImpDehydratedItem *> *_Nonnull const itemsThatNeedToBeAddedToTheirParents = [NSMutableArray arrayWithCapacity:totalNumItems / 2];

	__block ImpDehydratedItem *_Nullable rootItem = nil;

	[catalog walkLeafNodes:^bool(ImpBTreeNode *const  _Nonnull node) {
		[node forEachHFSCatalogRecord_file:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogFile *const _Nonnull fileRec) {
			ImpDehydratedItem *_Nonnull const dehydratedFile = [[ImpDehydratedItem alloc] initWithHFSSourceVolume:hfsVolume catalogNodeID:L(fileRec->fileID) key:catalogKeyPtr fileRecord:fileRec];

			ImpDehydratedItem *_Nullable const parent = dehydratedFolders[@(L(catalogKeyPtr->parentID))];
			if (parent != nil) {
				[parent addChildrenObject:dehydratedFile];
			} else {
				[itemsThatNeedToBeAddedToTheirParents addObject:dehydratedFile];
			}
		} folder:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogFolder *const _Nonnull folderRec) {
			ImpDehydratedItem *_Nonnull const dehydratedFolder = [[ImpDehydratedItem alloc] initWithHFSSourceVolume:hfsVolume catalogNodeID:L(folderRec->folderID) key:catalogKeyPtr folderRecord:folderRec];
			dehydratedFolder->_children = [NSMutableArray arrayWithCapacity:L(folderRec->valence)];

			dehydratedFolders[@(dehydratedFolder.catalogNodeID)] = dehydratedFolder;

			HFSCatalogNodeID const parentID = L(catalogKeyPtr->parentID);
			if (parentID == kHFSRootParentID) {
				rootItem = dehydratedFolder;
			} else {
				ImpDehydratedItem *_Nullable const parent = dehydratedFolders[@(parentID)];
				if (parent != nil) {
					[parent addChildrenObject:dehydratedFolder];
				} else {
					[itemsThatNeedToBeAddedToTheirParents addObject:dehydratedFolder];
				}
			}
		} thread:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogThread *const _Nonnull threadRec) {
			//Not sure we have anything to do for threads?
		}];

		[node forEachHFSPlusCatalogRecord_file:^(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSPlusCatalogFile const *_Nonnull const fileRec) {
			ImpDehydratedItem *_Nonnull const dehydratedFile = [[ImpDehydratedItem alloc] initWithHFSPlusSourceVolume:hfsPlusVolume
				catalogNodeID:L(fileRec->fileID)
				key:catalogKeyPtr
				fileRecord:fileRec];

			ImpDehydratedItem *_Nullable const parent = dehydratedFolders[@(L(catalogKeyPtr->parentID))];
			if (parent != nil) {
				[parent addChildrenObject:dehydratedFile];
			} else {
				[itemsThatNeedToBeAddedToTheirParents addObject:dehydratedFile];
			}
		} folder:^(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSPlusCatalogFolder const *_Nonnull const folderRec) {
			ImpDehydratedItem *_Nonnull const dehydratedFolder = [[ImpDehydratedItem alloc] initWithHFSPlusSourceVolume:hfsPlusVolume
				catalogNodeID:L(folderRec->folderID)
				key:catalogKeyPtr
				folderRecord:folderRec];
			dehydratedFolder->_children = [NSMutableArray arrayWithCapacity:L(folderRec->valence)];

			dehydratedFolders[@(dehydratedFolder.catalogNodeID)] = dehydratedFolder;

			HFSCatalogNodeID const parentID = L(catalogKeyPtr->parentID);
			if (parentID == kHFSRootParentID) {
				rootItem = dehydratedFolder;
			} else {
				ImpDehydratedItem *_Nullable const parent = dehydratedFolders[@(parentID)];
				if (parent != nil) {
					[parent addChildrenObject:dehydratedFolder];
				} else {
					[itemsThatNeedToBeAddedToTheirParents addObject:dehydratedFolder];
				}
			}
		} thread:nil];

		return true;
	}];


	for (ImpDehydratedItem *_Nonnull const item in itemsThatNeedToBeAddedToTheirParents) {
		[dehydratedFolders[@(item.parentFolderID)] addChildrenObject:item];
	}

	return dehydratedFolders[@(kHFSRootFolderID)];
}

- (void) printDirectoryHierarchy_asPaths:(bool)printAbsolutePaths {
	NSString *_Nonnull (^firstColumnForItem)(ImpDehydratedItem *_Nonnull const item, NSUInteger const depth) = (
		printAbsolutePaths
		? ^NSString *_Nonnull(ImpDehydratedItem *_Nonnull const item, NSUInteger const depth)
		{
			NSArray <NSString *> *_Nonnull const path = item.path;
			NSString *_Nonnull const pathStr = [path componentsJoinedByString:@":"];
			return (item.isDirectory) ? [pathStr stringByAppendingString:@":"] : pathStr;
		}
		: ^NSString *_Nonnull(ImpDehydratedItem *_Nonnull const item, NSUInteger const depth)
		{
			NSMutableString *_Nonnull const spaces = [
				@" " @" " @" " @" "
				@" " @" " @" " @" "
				@" " @" " @" " @" "
				@" " @" " @" " @" "
				mutableCopy];
			NSString *_Nonnull(^_Nonnull const indentWithDepth)(NSUInteger const depth) = ^NSString *_Nonnull(NSUInteger const numSpacesRequested) {
				if (numSpacesRequested > spaces.length) {
					NSRange extendRange = { spaces.length, numSpacesRequested - spaces.length };
					for (NSUInteger i = extendRange.location; i < numSpacesRequested; ++i) {
						[spaces appendString:@" "];
					}
				}
				return [spaces substringToIndex:numSpacesRequested];
			};
			return [NSString stringWithFormat:@"%@%@ %@", indentWithDepth(depth), item.iconEmojiString, item.name];
		}
	);

	ImpSourceVolume *_Nullable const volume = self.sourceVolume;

	ImpDehydratedItem *_Nonnull const rootDirectory = self;
	ImpPrintf(@"Volume name:\t%@", rootDirectory.name);
	ImpPrintf(@"Created:\t%@", rootDirectory.creationDate);
	ImpPrintf(@"Last modified:\t%@", rootDirectory.modificationDate);

	NSByteCountFormatter *_Nonnull const bcf = [NSByteCountFormatter new];
	NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
	fmtr.numberStyle = NSNumberFormatterDecimalStyle;
//	fmtr.hasThousandSeparators = true;

	NSUInteger volumeCapacity = 0;
	NSUInteger const blockSize = volume.numberOfBytesPerBlock;
	NSUInteger const numBlocksTotal = volume.numberOfBlocksTotal;
	if (os_mul_overflow(blockSize, numBlocksTotal, &volumeCapacity)) {
		ImpPrintf(@"Capacity:\t%@ (%@ blocks of %@ bytes each)", @"huge", [fmtr stringFromNumber:@(numBlocksTotal)], [fmtr stringFromNumber:@(blockSize)]);
	} else {
		ImpPrintf(@"Capacity:\t%@ (%@ bytes across %@ blocks)", [bcf stringFromByteCount:volumeCapacity], [fmtr stringFromNumber:@(volumeCapacity)], [fmtr stringFromNumber:@(numBlocksTotal)]);
	}
	NSUInteger const blocksUsed = volume.numberOfBlocksUsed;
	NSUInteger const bytesUsed = blockSize * blocksUsed;
	ImpPrintf(@"Used:\t%@ (%@ bytes across %@ blocks)", [bcf stringFromByteCount:bytesUsed], [fmtr stringFromNumber:@(bytesUsed)], [fmtr stringFromNumber:@(blocksUsed)]);
	NSUInteger const blocksFree = volume.numberOfBlocksFree;
	NSUInteger const bytesFree = blockSize * blocksFree;
	ImpPrintf(@"Free:\t%@ (%@ bytes across %@ blocks)", [bcf stringFromByteCount:bytesFree], [fmtr stringFromNumber:@(bytesFree)], [fmtr stringFromNumber:@(blocksFree)]);
	ImpPrintf(@"");

	ImpPrintf(@"%@   \tData size\tRsrc size\tTotal size", printAbsolutePaths ? @"Path" : @"Name");
	ImpPrintf(@"═══════\t═════════\t═════════\t═════════");

	__block u_int64_t totalDF = 0, totalRF = 0, totalTotal = 0;

	__block NSUInteger lastKnownDepth = 0;
	[rootDirectory walkBreadthFirst:^(NSUInteger const depth, ImpDehydratedItem *_Nonnull const item) {
		if (item == nil) {
			ImpPrintf(@"");
			return;
		}

		lastKnownDepth = depth;
		switch (item.type) {
			case ImpDehydratedItemTypeFile: {
				u_int64_t const sizeDF = item.dataForkLogicalLength, sizeRF = item.resourceForkLogicalLength, sizeTotal = sizeDF + sizeRF;
				totalDF += sizeDF;
				totalRF += sizeRF;
				totalTotal += sizeTotal;
				ImpPrintf(@"%@\t%9@\t%9@\t%9@", firstColumnForItem(item, depth), [fmtr stringFromNumber:@(sizeDF)], [fmtr stringFromNumber:@(sizeRF)], [fmtr stringFromNumber:@(sizeTotal)]);
				break;
			}
			case ImpDehydratedItemTypeFolder:
			case ImpDehydratedItemTypeVolume:
				ImpPrintf(@"%@ contains %lu items", firstColumnForItem(item, depth), (unsigned long)[item countOfChildren]);
				break;
			default:
				ImpPrintf(@"%@", firstColumnForItem(item, depth));
				break;
		}
		if (depth != lastKnownDepth) ImpPrintf(@"");
	}];
	ImpPrintf(@"═══════\t═════════\t═════════\t═════════");
	ImpPrintf(@"%@\t%9@\t%9@\t%9@", @"Total", [fmtr stringFromNumber:@(totalDF)], [fmtr stringFromNumber:@(totalRF)], [fmtr stringFromNumber:@(totalTotal)]);

	//Lastly, report the sizes of the catalog and extents files.
	bool const includeCatAndExt = false;
	if (includeCatAndExt) {
		ImpPrintf(@"═══════\t═════════\t═════════\t═════════");
		{
			u_int64_t const sizeDF = volume.catalogSizeInBytes, sizeRF = 0, sizeTotal = sizeDF + sizeRF;
			totalDF += sizeDF;
			totalRF += sizeRF;
			totalTotal += sizeTotal;
			ImpPrintf(@"%@ %@\t%9@\t%9@\t%9@", @"🗃", @"Catalog", [fmtr stringFromNumber:@(sizeDF)], [fmtr stringFromNumber:@(sizeRF)], [fmtr stringFromNumber:@(sizeTotal)]);
		}
		{
			u_int64_t const sizeDF = volume.extentsOverflowSizeInBytes, sizeRF = 0, sizeTotal = sizeDF + sizeRF;
			totalDF += sizeDF;
			totalRF += sizeRF;
			totalTotal += sizeTotal;
			ImpPrintf(@"%@ %@\t%9@\t%9@\t%9@", @"🗃", @"Extents", [fmtr stringFromNumber:@(sizeDF)], [fmtr stringFromNumber:@(sizeRF)], [fmtr stringFromNumber:@(sizeTotal)]);
		}
		ImpPrintf(@"═══════\t═════════\t═════════\t═════════");
		ImpPrintf(@"%@\t%9@\t%9@\t%9@", @"Total", [fmtr stringFromNumber:@(totalDF)], [fmtr stringFromNumber:@(totalRF)], [fmtr stringFromNumber:@(totalTotal)]);
	}
}
- (NSUInteger) countOfChildren {
	return _children.count;
}
- (void) addChildrenObject:(ImpDehydratedItem *_Nonnull const)object {
	[_children addObject:object];
}

@end
