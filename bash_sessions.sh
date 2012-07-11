#!/bin/bash
#
# Session support for bash
#

# Todo:
#  * I'm sure session names with a "/" will cause horrible problems.
#  * Need to fix saving of arrays

# Each session is stored in a subdirectory under ${BASH_SESSION_DIR}.
# Each subdirectory contains multiple files capturing the
# session. They are created by _session_save() to save the session and
# then sourced by _session_load() to load the session.
#
# The files are:
#    history         - the session history
#    session-*.sh    - Files source by _session_load() in alphanumeric order
#                      to load the session.
#    load.sh         - File that should be sourced to load the session.
#    user.sh         - A user creatable file (never written by session) sourced
#                      after all the session files.
#    lock.pid        - A file containing the pid of the shell currently
#                      holding the lock on the sesssion.

# Where we store session state.
BASH_SESSIONS_DIR=${BASH_SESSIONS_DIR:-~/.bash_sessions}

# Where we can find this file, so we can copy it into session directories
BASH_SESSIONS_FILE=${BASH_ARGV[0]}

# If BASH_SESSION_NO_SAVE=1 then session won't be saved on exit
# It is normally set by 'session nosave'
BASH_SESSION_NO_SAVE=0

# $BASH_SESSION_LAUNCH_COMMAND is executed when a session is launched.

# $BASH_SESSION_EXIT_COMMAND is executed when a session is exited.

######################################################################
#
# Main point of entry


function session()
{
    local usage="\
usage:
 ${FUNCNAME} <-h|help>              # Print help
 ${FUNCNAME} launch <session name>  # Starts session in a subshell
				    # Creates session if it doesn't exist.
 ${FUNCNAME} exec <session name>    # Replaces current shell with session.
				    # Creates session if it doesn't exist.


 ${FUNCNAME} in-session             # Return 0 if in a session, 1 otherwise
 ${FUNCNAME} list                   # List all sessions
 ${FUNCNAME} name                   # Print session name (or nothing)
 ${FUNCNAME} delete <session name>  # Delete given session
 ${FUNCNAME} nosave                 # Don't save session state on exit
 ${FUNCNAME} save [<session name>]  # Save session snapshot.
				    # If name given, save as given name.
				    # If not in  session, name must
				    # be provided.
 ${FUNCNAME} unlock <session name>  # Unlock session
"
    if test $# -eq 0 ; then
	echo "Argument required."
	echo "${usage}"
	return 1
    fi
    local arg=${1}; shift
    case ${arg} in
	delete) # Delete session
	    if test $# -ne 1 ; then
		echo "-d requires session name"
		return 1
	    fi
	    _session_delete ${@} || return 1
	    ;;
	exec) # Exec session
	    echo "Execing session ${1}"
	    _session_exec ${1} || return 1
	    # Will never get here.
	    ;;
	-h|help) # Print help
	    echo "${usage}"
	    ;;
	in-session) # Return 0 if in valid session, 1 otherwise
	    _session_in_valid && return 0
	    return 1
	    ;;
	launch) # Start given session
	    echo "Starting session ${1}"
	    _session_launch ${1} || return 1
	    ;;
	list) # List sessions
	    _session_list
	    ;;
	name) # Print current session name
	    _session_name
	    ;;
	nosave) # Do not save session on exit
	    export BASH_SESSION_NO_SAVE=1
	    echo "Session will not be saved on exit"
	    ;;
	save) # Save session snapshot
	    if test $# -eq 0 ; then
		if _session_in_valid ; then
		    :
		else
		    echo "Not in session. Must provide session name."
		    return 1
		fi
	    fi
	    _session_save "$@" || return 1
	    if test $# -eq 0 ; then
		echo "Session saved."
	    else
		echo "Session ${1} saved."
	    fi
	    ;;
	unlock) # Unlock given session
	    if test $# -ne 1 ; then
		echo "-U requires session name"
		return 1
	    fi
	    _session_unlock ${@} || return 1
	    echo "Session ${1} unlocked"
	    ;;
	*)
	    echo "Unknown option: ${arg}"
	    echo "${usage}"
	    return 1
	    ;;
    esac
    return 0
}

######################################################################
#
# Main commands

function _session_name()
{
    # Print session name if we are in session
    _session_in_valid && echo "${BASH_SESSION}"
}

function _session_save()
{
    # Save current state
    # Optional argument specifes session name to save under
    if test $# -eq 0 ; then
	# If not session name provided, must be in session
	_session_in_valid || return 1
	local _dir=$(_session_dir)
    else
	local _dir=$(_session_dir ${1})
    fi
    if test -d ${_dir} ; then
	# Remove old session load files.
	# We do this in case we have a session-profile.sh we should only
	# run the first time. Or the session was last saved by an older
	# version of bash_sessions that created a sessions-*.sh file that
	# is no longer needed. Do with nullglob to allow for no files
	# existing (in which case the 'rm -f' does nothing).
	( shopt -s nullglob ; rm -f ${_dir}/sessions-*.sh )
    else
	mkdir ${_dir}
    fi
    _session_create_load_file ${_dir}/load.sh
    _session_dirstack_commands > ${_dir}/session-dirstack.sh
    set > ${_dir}/session-set.sh
    alias > ${_dir}/session-alias.sh
    echo "umask $(umask)" > ${_dir}/session-umask.sh
    trap -p > ${_dir}/session-trap.sh
    shopt -p > ${_dir}/session-shopt.sh
    # This doesn't really work. Until an array is referenced, declare -ap
    # will always show it as being empty. One needs to do a access first,
    # e.g.: echo ${ARRAY[*]}
    declare -ap > ${_dir}/session-arrays.sh

    # 'declare -x' when used in a function makes the variable local
    # which causes all sorts of problems when _session_load() sources
    # the following. So we need to use 'export' instead.
    export -p | sed -e "s/declare -x/export/g" > \
	${_dir}/session-export.sh

    readonly -p > ${_dir}/session-readonly.sh
    declare -pi > ${_dir}/session-integers.sh
    history -w
}

function _session_exec() # <session_name>
{
    _session_launch -e "$@"  # Will not return
}

function _session_launch()  # [-e] <session_name>
{
    # Start new session given by ${1}
    # If -e is given, exec's the session instead of starting in subshell
    # Will create new session if needed
    local usage="usage: ${FUNCNAME}: <session name>"
    if test "X${1}" = "X-e" ; then
	shift
	local _bash="exec /bin/bash"
	export BASH_SESSION_SUBSHELL=0
    else
	local _bash="bash"
	export BASH_SESSION_SUBSHELL=1
    fi
    local _new_session=${1:?$usage} ; shift

    test -d ${BASH_SESSIONS_DIR} || mkdir ${BASH_SESSIONS_DIR}

    # We will lock the session in load.sh, but check here as it's
    # an easier error to handle. This does however leave a small race
    # condition where the session could be locked by someone else between
    # here and load.sh locking it.
    if _session_locked ${_new_session} ; then
	_session_lock_msg ${_new_session}
	return 1
    fi

    _session_valid ${_new_session} || _session_create ${_new_session}

    local _dir=$(_session_dir ${_new_session})
    local _load_file=${_dir}/load.sh

    if test -f ${_load_file} ; then
	:
    else
	echo "Cannot load session \"$(_session_name)\": load.sh does not exist."
	return 1
    fi

    ${_bash} --init-file ${_load_file}
    # If ${bash} is 'exec bash' we won't reach this point.
    unset BASH_SESSION_SUBSHELL
    return 0
}

function _session_create()
{
    # Create a new session
    local usage="usage: ${FUNCNAME}: <session name>"
    local _new_session=${1:?$usage} ; shift
    local _dir=$(_session_dir $_new_session)

    test -d ${_dir} || mkdir -p ${_dir}
    # Copy this very file to the directory so load.sh can source it
    cp ${BASH_SESSIONS_FILE} ${_dir}
    _session_create_load_file ${_dir}/load.sh

    # The first time we load a session we want it to source the
    # user's ~/.bashrc, so create a file doing that.
    echo "test -f ~/.bashrc && source ~/.bashrc" > ${_dir}/session-bashrc.sh
}

function _session_list()
{
    # Print list of sessions, one per line
    test -d ${BASH_SESSIONS_DIR} || return 0
    # Run in subshell to prevent changing current directory
    (
	cd ${BASH_SESSIONS_DIR} || return 1
	for dir in * ; do
	    test -d ${dir} && echo ${dir%/}
	done
	)
    return 0
}

function _session_delete() # <session_name>
{
    # Delete the given session. Must be unlocked
    local _name=${1:?"usage: ${FUNCNAME} <session name>"}
    if _session_valid ${_name} ; then
	:
    else
	echo "Session '${_name}' invalid"
	return 1
    fi
    if _session_locked ${_name} ; then
	_session_lock_msg ${_name}
	return 1
    fi
    local _dir=$(_session_dir ${_name})
    echo "Deleting session '${_name}' (${_dir})"
    rm -f ${_dir}/*
    rmdir ${_dir}
}

######################################################################
#
# Session loading support functions

function _session_create_load_file()
{
    # Create a file that will load the session in its directory
    local usage="usage: ${FUNCNAME}: <file name>"
    local _filename=${1:?$usage} ; shift
    (
	echo "# load.sh created $(date)"
	echo "source ${BASH_SESSIONS_FILE}"
	echo "_session_load_file_internal || _session_load_error"
    ) > ${_filename}
    return 0
}

function _session_load_file_internal()
{
    # Load the session in the directory in which this script is contained
    # Intended to be called only in load.sh after sourcing a copy of this
    # file.

    # Get directory containing file being sourced
    local _dir=$(dirname ${BASH_ARGV[0]})

    if test -d ${_dir} ; then
	:
    else
	echo "_session_load_file_internal(): cannot determine directory"
	return 1
    fi

    local _name=$(basename ${_dir})

    _session_lock ${_name} || return 1

    # Save variables whose state shouldn't come from session
    local _BASH_SESSION_SHLVL=${SHLVL}

    # Get list of session files, allowing for empty directory
    local _files=$( \
	shopt -s nullglob ; \
	echo ${_dir}/session-*.sh ;
	)
    local file
    # Source files ignoring attempts to set readonly variables
    # ('set' outputs errors to stdout, 'declare' to stderr)
    # Note we can't just redirect output from source as that causes
    # it to run in a subshell and we lose what it does.
    exec 6>&1 1>&- 7>&2 2>&-  # Save and close output descriptors
    for file in ${_files}; do
	source ${file}
    done
    exec 1>&6 6>&- 2>&7 7>&-  # Restore output

    # Set up history
    history -c  # Clear old history
    export HISTFILE=${_dir}/history
    if test -f ${HISTFILE} ; then
	history -r  # Load history from ${HISTFILE}
    fi

    # Restore saved variables
    export SHLVL=${_BASH_SESSION_SHLVL}

    export BASH_SESSION=${_name}

    # Run user commands
    if test -n "${BASH_SESSION_LAUNCH_COMMAND}" ; then
	${BASH_SESSION_LAUNCH_COMMAND}
    fi

    # user.sh allows users to run custom commands.
    test -f ${_dir}/user.sh && \
	source ${_dir}/user.sh

    trap _session_exit EXIT
}

function _session_load_error()
{
    # Handle an error in session_load_internal
    echo "Error launching session."
    if test "${BASH_SESSION_SUBSHELL}" -eq 1 ; then
	# This is a subshell, just exit
	exit 1
    else
	# We were exec'ed, so we've replaced the calling shell.
	# If we exit, we kill the user's calling shell.
	# But at this point we're in a bash shell with no initialization.
	# Don't know what else we can do though.
	:
    fi
}

function _session_exit()
{
    # handle session exit
    # Meant to be called by 'trap _session_exit EXIT'
    if test -n "${BASH_SESSION_EXIT_COMMAND}" ; then
	${BASH_SESSION_EXIT_COMMAND}
    fi
    _session_in_valid || return 1
    if test "X${BASH_SESSION_NO_SAVE}" != "X1" ; then
	_session_save
    fi
    _session_unlock
    unset BASH_SESSION
}

######################################################################
#
# Saving support functions
#

function _session_dirstack_commands()
{
    # Generate commands to recreate our directory stack
    local _count=1
    local _cmd=""
    for path in "${DIRSTACK[@]}" ; do
	if test -n "${_cmd}" ; then
	    _cmd="; ${_cmd}"
	fi
	# Need to replace '~' with '${HOME}' so that it expands
	# correctly when sourced in quotes.
	path=`echo ${path} | sed -e s/\~/\\${HOME}/`
	# Last element is a cd not a pushd
	if test ${_count} -eq ${#DIRSTACK[@]} ; then
	    _cmd="cd \"${path}\" ${_cmd}"
	else
	    _cmd="pushd \"${path}\" ${_cmd}"
	fi
	((_count++))
    done
    echo ${_cmd}
}

######################################################################
#
# Session locking functions

function _session_lock_file() # <session_name
{
    # Print name of session lock file
    local _name=${1:?"usage: ${FUNCNAME} <session name>"}
    echo ${BASH_SESSIONS_DIR}/${_name}/lock.pid
}

function _session_locked() # <session_name>
{
    # Return 0 if session is locked, 1 otherwise
    local _name=${1:?"usage: ${FUNCNAME} <session name>"}
    local _lock_file=$(_session_lock_file ${_name})
    test -f ${_lock_file} && return 0
    return 1
}

function _session_locked_by() # <session_mame>
{
    # Echo the PID of shell using the given session_name
    local _name=${1:?"usage: ${FUNCNAME} <session name>"}
    local _lock_file=$(_session_lock_file ${_name})
    test -f ${_lock_file} && cat ${_lock_file}
    return 0
}

function _session_lock() # <session_name>
{
    # Lock the given session. Return 0 on success, 1 on error
    local _name=${1:?"usage: ${FUNCNAME} <session name>"}
    local _lock_file=$(_session_lock_file ${_name})
    local _dir=$(_session_dir ${_name})
    test -d ${_dir} || mkdir -p ${_dir}
    if test -f ${_lock_file} ; then
	_session_lock_msg ${_name}
	return 1
    fi
    echo $$ > ${_lock_file}
    return 0
}

function _session_lock_msg() # <session_name>
{
    # Print a message that session is locked
    local _name=${1:?"usage: ${FUNCNAME} <session name>"}
    _session_locked ${_name} || return 1
    echo "Session '${_name}' is locked by $(_session_locked_by ${_name})"
    echo "  Remove $(_session_lock_file ${_name}) to unlock."
}

function _session_unlock() # <session_name>
{
    # Lock the given session (or current session if no argument)
    local _name=${1:-${BASH_SESSION:?"No current session"}}
    local _lock_file=$(_session_lock_file ${_name})
    rm -f ${_lock_file}
    return 0
}

######################################################################
#
# Support functions

function _session_dir() # [<session_name>]
{
    # Return directory for given session or current if none given
    local _name=${1:-${BASH_SESSION:?"No current session"}}
    local _dir=${BASH_SESSIONS_DIR}/${_name}
    echo ${_dir}
}

function _session_in_valid()
{
    # Return 0 if we are in a valid session
    test -n "${BASH_SESSION}"
}

function _session_valid() # <session_name>
{
    # Return 0 if given session is a valid session
    local _name=${1:?"usage: ${FUNCNAME} <session name>"}
    test -n "${_name}" || return 1
    local _dir=${BASH_SESSIONS_DIR}/${_name}
    test -d ${_dir} || return 1
}

######################################################################
#
# Extras

function _session_complete()
{
    # Function for use in complete
    # E.g.: complete -F _session_complete session
    local _command=${1}
    local _word_being_completed=${2}
    local _previous_word=${3}

    local _words=""
    local _cmds="delete exec -h help in-session launch list name nosave save"
    case ${COMP_CWORD} in
	1)  # First argument must be command
	    #
	    _words="${_cmds}"
	    ;;
	2)  # Second argument.
	    # Complete on session list only for arguments that take
	    # a session name.
	    case ${_previous_word} in
		delete|exec|launch|unlock)
		    _words=$(_session_list)
		    ;;
	    esac
	    ;;
    esac

    COMPREPLY=( $(compgen -W "${_words}" ${_word_being_completed}) )
}

function _session_ps1()
{
    # Return string for inclusion in PS1
    # Returns nothing if not in session
    # Optional argument is format string, default is [%s]
    # Example: PS1="(\u@]h)$(_session_ps1) $"
    _session_in_valid || return
    printf "${1:-[%s]}" $(_session_name)
}
