/**
 * Fixed size object storage with CRC in BlockStorage.
 *
 * @author Raido Pahtma
 * @license MIT
 */
#include "Storage.h"
generic configuration FixedObjectStorageC(volume_id_t volid, typedef object_type) {
	provides {
		interface FixedObjectStorage<object_type>;
	}
}
implementation {

	components new FixedObjectStorageP(object_type, unique("FixedObjectStorageP"));
	FixedObjectStorage = FixedObjectStorageP;

	components new BlockStorageC(volid);
	FixedObjectStorageP.BlockRead -> BlockStorageC.BlockRead;
	FixedObjectStorageP.BlockWrite -> BlockStorageC.BlockWrite;

}
