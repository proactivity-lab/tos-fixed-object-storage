/**
 * Fixed size object storage with CRC in BlockStorage.
 *
 * @author Raido Pahtma
 * @license MIT
 */
#include "crc.h"
generic module FixedObjectStorageP(typedef object_type) {
	provides {
		interface FixedObjectStorage<object_type>;
	}
	uses {
		interface BlockRead;
		interface BlockWrite;
		interface Timer<TMilli> as SyncDelay;
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
	uint8_t m_sync = FALSE;

	uint8_t m_storage_id;
	storage_unit_t m_storage;

	uint16_t computeCrc(uint8_t buf[], uint16_t length) {
		uint16_t i;
		uint16_t c = 0;
		for(i=0;i<length;i++) {
			c = crcByte(c, buf[i]);
		}
		return c;
	}

	task void tick() {
		if(m_sync == FALSE) {
			error_t err;
			switch(m_state) {
				case ST_STORE:
					err = call BlockWrite.write(sizeof(m_storage)*m_storage_id, &m_storage, sizeof(m_storage));
					if(err != SUCCESS) {
						err1("write");
						m_state = ST_IDLE;
						signal FixedObjectStorage.storeDone(FAIL, m_storage_id);
					}
					break;
				case ST_REMOVE:
					err = call BlockWrite.write(sizeof(m_storage)*m_storage_id, &m_storage, sizeof(m_storage));
					if(err != SUCCESS) {
						err1("remove");
						m_state = ST_IDLE;
						signal FixedObjectStorage.removeDone(FAIL, m_storage_id);
					}
					break;
				case ST_GET:
					err = call BlockRead.read(sizeof(m_storage)*m_storage_id, &m_storage, sizeof(m_storage));
					if(err != SUCCESS) {
						err1("read");
						m_state = ST_IDLE;
						signal FixedObjectStorage.retrieveDone(FAIL, m_storage_id, NULL);
					}
					break;
			}
		}
		else debug1("syncb");
	}

	command bool FixedObjectStorage.busy() {
		return m_state != ST_IDLE;
	}

	command uint16_t FixedObjectStorage.size() {
		return call BlockRead.getSize()/sizeof(m_storage);
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
		m_state = ST_IDLE;
		if(result == SUCCESS) {
			uint16_t c = computeCrc((uint8_t*)&m_storage, sizeof(m_storage) - sizeof(m_storage.crc));
			if(m_storage.crc == c) {
				if(m_storage.uidhash == IDENT_UIDHASH) {
					signal FixedObjectStorage.retrieveDone(SUCCESS, m_storage_id, (object_type*)m_storage.data);
					return;
				}
				else debug1("uidhash mismatch");
			}
			else debug1("crc mismatch %04x != %04x", m_storage.crc, c); // Could be empty, could be broken
		}
		signal FixedObjectStorage.retrieveDone(FAIL, m_storage_id, NULL);
	}

	event void BlockRead.computeCrcDone(storage_addr_t x, storage_len_t y, uint16_t z, error_t result) { }

	event void BlockWrite.writeDone(storage_addr_t addr, void *buf, storage_len_t len, error_t error) {
		switch(m_state) {
			case ST_STORE:
				logger(error == SUCCESS ? LOG_DEBUG1: LOG_ERR1, "str %u", error);
				m_state = ST_IDLE;
				signal FixedObjectStorage.storeDone(error, m_storage_id);
				break;
			case ST_REMOVE:
				logger(error == SUCCESS ? LOG_DEBUG1: LOG_ERR1, "rem %u", error);
				m_state = ST_IDLE;
				signal FixedObjectStorage.removeDone(error, m_storage_id);
				break;
		}
		call SyncDelay.startOneShot(1000);
	}

	event void SyncDelay.fired() {
		if(m_state == ST_IDLE) {
			error_t err = call BlockWrite.sync();
			logger(err == SUCCESS ? LOG_DEBUG1: LOG_ERR1, "s %u", err);
			if(err == SUCCESS) {
				m_sync = TRUE;
				return;
			}
		}
		call SyncDelay.startOneShot(1000);
	}

	event void BlockWrite.eraseDone(error_t error) { }

	event void BlockWrite.syncDone(error_t error) {
		logger(error == SUCCESS ? LOG_DEBUG1: LOG_ERR1, "sD %u", error);
		m_sync = FALSE;
		if(m_state != ST_IDLE) {
			post tick();
		}
	}

}
