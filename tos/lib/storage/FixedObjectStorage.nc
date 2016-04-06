/**
 * Fixed size object storage with CRC in BlockStorage.
 *
 * @author Raido Pahtma
 * @license MIT
 */
interface FixedObjectStorage<object_type> {

	command bool busy();

	command uint16_t size();

	command error_t store(uint16_t id, object_type* object);
	event void storeDone(error_t result, uint16_t id);

	command error_t retrieve(uint16_t id);
	event void retrieveDone(error_t result, uint16_t id, object_type* object);

	command error_t remove(uint16_t id);
	event void removeDone(error_t result, uint16_t id);

}
