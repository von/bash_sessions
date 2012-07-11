prefix=/usr/local

.PHONY: install
install:
	install -C bash_sessions.sh ${prefix}/bin/bash_sessions
