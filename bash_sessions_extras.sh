
function _session_complete()
{
    # Function for use in complete
    # E.g.: complete -F _session_complete bash_sessions
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
		    _words=$(bash_sessions list)
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
    test -n ${BASH_SESSION} || return
    printf "${1:-[%s]}" ${$BASH_SESSION}
}
