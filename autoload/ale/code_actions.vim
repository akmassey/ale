" Author: w0rp <devw0rp@gmail.com>
" Description: Get and run code actions for language servers.

let s:code_actions_map = {}

" Used to get the map in tests.
function! ale#code_actions#GetMap() abort
    return deepcopy(s:code_actions_map)
endfunction

" Used to set the map in tests.
function! ale#code_actions#SetMap(map) abort
    let s:code_actions_map = a:map
endfunction

function! ale#code_actions#ClearLSPData() abort
    let s:code_actions_map = {}
endfunction

function! s:EscapeMenuName(text) abort
    return substitute(a:text, '\\\| \|\.\|&', '\\\0', 'g')
endfunction

function! ale#code_actions#Execute(conn_id, location, linter_name, id) abort
    if a:linter_name is# 'tsserver'
        let [l:refactor, l:action] = a:id

        let l:message = ale#lsp#tsserver_message#GetEditsForRefactor(
        \   a:location.buffer,
        \   a:location.line,
        \   a:location.column,
        \   a:location.end_line,
        \   a:location.end_column,
        \   l:refactor,
        \   l:action,
        \)

        let l:request_id = ale#lsp#Send(a:conn_id, l:message)

        let s:code_actions_map[l:request_id] = {}
    endif
endfunction

function! s:UpdateMenu(conn_id, location, linter_name, menu_items) abort
    silent! aunmenu PopUp.Refactor\.\.\.

    for l:item in a:menu_items
        execute printf(
        \   'anoremenu <silent> PopUp.&Refactor\.\.\..%s'
        \       . ' :call ale#code_actions#Execute(%s, %s, %s, %s)<CR>',
        \   join(map(copy(l:item.names), 's:EscapeMenuName(v:val)'), '.'),
        \   string(a:conn_id),
        \   string(a:location),
        \   string(a:linter_name),
        \   string(l:item.id)
        \)
    endfor
endfunction

function! ale#code_actions#HandleTSServerResponse(conn_id, response) abort
    if get(a:response, 'command', '') is# 'getApplicableRefactors'
    \&& has_key(s:code_actions_map, a:response.request_seq)
        let l:details = remove(s:code_actions_map, a:response.request_seq)

        let l:conn_id = l:details.connection_id
        let l:location = l:details.location
        let l:linter_name = l:details.linter_name
        let l:menu_items = []

        if get(a:response, 'success', v:false) is v:true
        \&& !empty(get(a:response, 'body'))
            for l:item in a:response.body
                for l:action in l:item.actions
                    " Actions for inlineable items can top level items.
                    call add(l:menu_items, {
                    \   'names': get(l:item, 'inlineable')
                    \       ? [l:item.description, l:action.description]
                    \       : [l:action.description],
                    \   'id': [l:item.name, l:action.name],
                    \})
                endfor
            endfor
        endif

        call s:UpdateMenu(l:conn_id, l:location, l:linter_name, l:menu_items)
    endif

    if get(a:response, 'command', '') is# 'getEditsForRefactor'
    \&& has_key(s:code_actions_map, a:response.request_seq)
        if get(a:response, 'success', v:false) is v:true
        \&& !empty(get(a:response, 'body'))
            " Could be set for a location: a:response.renameLocation
            for l:item in a:response.body.edits
                for l:edit in l:item.textChanges
                    echom printf(
                    \   '%s [%d, %d, %d, %d] %s',
                    \   l:item.fileName,
                    \   l:edit.start.line,
                    \   l:edit.start.offset,
                    \   l:edit.end.line,
                    \   l:edit.end.offset,
                    \   l:edit.newText,
                    \)
                endfor
            endfor
        endif
    endif
endfunction

function! ale#code_actions#HandleLSPResponse(conn_id, response) abort
    Dump a:response
endfunction

function! s:OnReady(location, options, linter, lsp_details) abort
    let l:id = a:lsp_details.connection_id

    if !ale#lsp#HasCapability(l:id, 'code_actions')
        return
    endif

    let l:buffer = a:lsp_details.buffer

    let l:Callback = a:linter.lsp is# 'tsserver'
    \   ? function('ale#code_actions#HandleTSServerResponse')
    \   : function('ale#code_actions#HandleLSPResponse')
    call ale#lsp#RegisterCallback(l:id, l:Callback)

    if a:linter.lsp is# 'tsserver'
        let l:message = ale#lsp#tsserver_message#GetApplicableRefactors(
        \   a:location.buffer,
        \   a:location.line,
        \   a:location.column,
        \   a:location.end_line,
        \   a:location.end_column,
        \)
    else
        " Send a message saying the buffer has changed first, or the
        " definition position probably won't make sense.
        call ale#lsp#NotifyForChanges(l:id, l:buffer)
        " TODO: Do this.
    endif

    let l:request_id = ale#lsp#Send(l:id, l:message)

    let s:code_actions_map[l:request_id] = {
    \   'connection_id': l:id,
    \   'location': a:location,
    \   'linter_name': a:linter.name,
    \}
endfunction

function! s:GetCodeActions(linter, options) abort
    let l:buffer = bufnr('')
    let [l:line, l:column] = getpos('.')[1:2]
    let l:column = min([l:column, len(getline(l:line))])

    let l:location = {
    \   'buffer': l:buffer,
    \   'line': l:line,
    \   'column': l:column,
    \   'end_line': l:line,
    \   'end_column': l:column,
    \}
    let l:Callback = function('s:OnReady', [l:location, a:options])
    call ale#lsp_linter#StartLSP(l:buffer, a:linter, l:Callback)
endfunction

function! ale#code_actions#GetCodeActions(options) abort
    silent! aunmenu PopUp.Refactor\.\.\.

    for l:linter in ale#linter#Get(&filetype)
        if !empty(l:linter.lsp)
            call s:GetCodeActions(l:linter, a:options)
        endif
    endfor
endfunction

function! s:Setup(enabled) abort
    augroup ALECodeActionsGroup
        autocmd!

        if a:enabled
            autocmd MenuPopup * :call ale#code_actions#GetCodeActions({})
        endif
    augroup END

    if !a:enabled
        augroup! ALECompletionGroup
    endif
endfunction

function! ale#code_actions#Enable() abort
    let g:ale_code_actions_enabled = 1
    call s:Setup(1)
endfunction

function! ale#code_actions#Disable() abort
    let g:ale_code_actions_enabled = 0
    call s:Setup(0)
endfunction
