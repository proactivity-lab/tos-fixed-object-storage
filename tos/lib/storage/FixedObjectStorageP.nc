/**
 * Fixed size object storage with CRC in BlockStorage.
 *
 * @author Raido Pahtma
 * @license MIT
 */

#ifndef SPIFFS_ENABLED
#include "HplAt45db_chip.h"
#endif//SPIFFS_ENABLED

#include "crc.h"
generic module FixedObjectStorageP(typedef object_type, uint8_t instance_id) {
	provides {
		interface FixedObjectStorage<object_type>;
	}
	uses {
		interface BlockRead;
		interface BlockWrite;
	}
}
implementation {

	#define __MODUUL__ "ostrg"
	#define __LOG_LEVEL__ (LOG_LEVEL_FixedSizeObjectStorageP & BASE_LOG_LEVEL)
	#include "log.h"

	typedef nx_struct storage_unit_t {
		nx_uint32_t uidhash;
		nx_uint8_t data[sizeof(object_type)];
		nx_uint16_t crc;
	} storage_unit_t;

	enum {
		ST_IDLE,
		ST_STORE,
		ST_REMOVE,
		ST_GET,
	};

	uint8_t m_state = ST_IDLE;

	uint8_t m_storage_id;
	storage_unit_t m_storage;

#ifndef SPIFFS_ENABLED
	// There seem to be issues with blockstorage when doing things that are not page-aligned. So align
	// everything with pages and work around the problems until BlockStorage can be abandoned in favor
	// of something better ... have high hopes for SPIFFS.
	#warning "Using page-aligned object storage to overcome BlockStorage bugs"
	const uint16_t object_storage_size = (1+((sizeof(m_storage)-1)/(1 << AT45_PAGE_SIZE_LOG2)))*(1 << AT45_PAGE_SIZE_LOG2);
#else // With SPIFFS_ENABLED, blockstorage is just a wrapper, so there should be no need to waste space
	const uint16_t object_storage_size = sizeof(m_storage);
#endif//SPIFFS_ENABLED

	uint16_t computeCrc(uint8_t buf[], uint16_t length) {
		uint16_t i;
		uint16_t c = 0;
		for(i=0;i<length;i++) {
			c = crcByte(c, buf[i]);
		}
		return c;
	}

	task void tick() {
		error_t err;
		switch(m_state) {
			case ST_STORE:
				err = call BlockWrite.write(object_storage_size*m_storage_id, &m_storage, sizeof(m_storage));
				if(err != SUCCESS) {
					err1("%d:write %d", instance_id, m_storage_id);
					m_state = ST_IDLE;
					signal FixedObjectStorage.storeDone(FAIL, m_storage_id);
				}
				break;
			case ST_REMOVE:
				err = call BlockWrite.write(object_storage_size*m_storage_id, &m_storage, sizeof(m_storage));
				if(err != SUCCESS) {
					err1("%d:remove %d", instance_id, m_storage_id);
					m_state = ST_IDLE;
					signal FixedObjectStorage.removeDone(FAIL, m_storage_id);
				}
				break;
			case ST_GET:
				err = call BlockRead.read(object_storage_size*m_storage_id, &m_storage, sizeof(m_storage));
				if(err != SUCCESS) {
					err1("%d:read %d", instance_id, m_storage_id);
					m_state = ST_IDLE;
					signal FixedObjectStorage.retrieveDone(FAIL, m_storage_id, NULL);
				}
				break;
		}
	}

	command bool FixedObjectStorage.busy() {
		return m_state != ST_IDLE;
	}

	command uint16_t FixedObjectStorage.size() {
		return call BlockRead.getSize()/object_storage_size;
	}

	command error_t FixedObjectStorage.retrieve(uint16_t id) {
		if(id < call FixedObjectStorage.size()) {
			if(m_state == ST_IDLE) {
				m_state = ST_GET;
				m_storage_id = id;
				post tick();
				return SUCCESS;
			}
			return EBUSY;
		}
		return EINVAL;
	}

	command error_t FixedObjectStorage.store(uint16_t id, object_type* object) {
		if(id < call FixedObjectStorage.size()) {
			if(m_state == ST_IDLE) {
				m_state = ST_STORE;
				m_storage_id = id;
				m_storage.uidhash = IDENT_UIDHASH;
				memcpy(m_storage.data, object, sizeof(object_type));
				m_storage.crc = computeCrc((uint8_t*)&m_storage, sizeof(m_storage) - sizeof(m_storage.crc));
				post tick();
				return SUCCESS;
			}
			return EBUSY;
		}
		return EINVAL;
	}

	command error_t FixedObjectStorage.remove(uint16_t id) {
		if(id < call FixedObjectStorage.size()) {
			if(m_state == ST_IDLE) {
				m_state = ST_REMOVE;
				m_storage_id = id;
				memset(&m_storage, 0xFF, sizeof(m_storage));
				post tick();
				return SUCCESS;
			}
			return EBUSY;
		}
		return EINVAL;
	}

	event void BlockRead.readDone(storage_addr_t x, void* buf, storage_len_t rlen, error_t result) {
		debug1("%d:rD(%"PRIu32",,%"PRIu32" %d)", instance_id, (uint32_t)x, (uint32_t)rlen, result);
		m_state = ST_IDLE;
		if(result == SUCCESS) {
			uint16_t c = computeCrc((uint8_t*)&m_storage, sizeof(m_storage) - sizeof(m_storage.crc));
			if(m_storage.crc == c) {
				if(m_storage.uidhash == IDENT_UIDHASH) {
					signal FixedObjectStorage.retrieveDone(SUCCESS, m_storage_id, (object_type*)m_storage.data);
				}
				else {
					warn1("%d:uidhash %"PRIx32"!=%"PRIx32" %d", instance_id, m_storage.uidhash, IDENT_UIDHASH, m_storage_id);
					signal FixedObjectStorage.retrieveDone(SUCCESS, m_storage_id, NULL);
				}
				return;
			}
			else {
				storage_len_t i;
				for(i=0;i<rlen;i++) {
					if(((uint8_t*)buf)[i] != 0xFF) {
						warnb1("%d:crc %04x!=%04x %d", (uint8_t*)buf, (uint8_t)rlen, instance_id, m_storage.crc, c, m_storage_id); // Stored data is broken
						signal FixedObjectStorage.retrieveDone(FAIL, m_storage_id, NULL);
						return;
					}
				}
				signal FixedObjectStorage.retrieveDone(SUCCESS, m_storage_id, NULL);
				return;
			}
		}
		signal FixedObjectStorage.retrieveDone(FAIL, m_storage_id, NULL);
	}

	event void BlockRead.computeCrcDone(storage_addr_t x, storage_len_t y, uint16_t z, error_t result) { }

	event void BlockWrite.writeDone(storage_addr_t addr, void *buf, storage_len_t len, error_t result) {
		if(result == SUCCESS) {
			error_t err = call BlockWrite.sync();
			logger(err == SUCCESS ? LOG_DEBUG1: LOG_ERR1, "%d:s %u", instance_id, err);
			if(err == SUCCESS) {
				return;
			}
		}

		// Something failed
		switch(m_state) {
			case ST_STORE:
				err1("%d:str %u (%u)", instance_id, m_storage_id, result);
				signal FixedObjectStorage.storeDone(result, m_storage_id);
				break;
			case ST_REMOVE:
				err1("%d:rem %u (%u)", instance_id, m_storage_id, result);
				signal FixedObjectStorage.removeDone(result, m_storage_id);
				break;
		}
		m_state = ST_IDLE;
	}

	event void BlockWrite.eraseDone(error_t error) { }

	event void BlockWrite.syncDone(error_t error) {
		switch(m_state) {
			case ST_STORE:
				logger(error == SUCCESS ? LOG_DEBUG1: LOG_ERR1, "%d:str %u (%u)", instance_id, m_storage_id, error);
				signal FixedObjectStorage.storeDone(error, m_storage_id);
				break;
			case ST_REMOVE:
				logger(error == SUCCESS ? LOG_DEBUG1: LOG_ERR1, "%d:rem %u (%u)", instance_id, m_storage_id, error);
				signal FixedObjectStorage.removeDone(error, m_storage_id);
				break;
		}
		m_state = ST_IDLE;
	}

}
