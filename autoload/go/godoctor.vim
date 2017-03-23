" Copyright 2015 Auburn University and The Go Authors. All rights reserved.
" Use of this source code is governed by a BSD-style
" license that can be found in the LICENSE file.

if !exists("g:go_godoctor_bin")
    let g:go_godoctor_bin = "godoctor"
endif

func! s:run_doctor(args) abort
endfunc

" Run the Go Doctor with the given selection, refactoring name, and arguments.
func! go#godoctor#Run(selected, refac, ...) range abort
  let cur_buf_file = expand('%:p')
  let bufcount = bufnr('$')

  " So, check that there is at most one unsaved buffer, and it has no name.
  " TODO need to check that there are no unsaved buffers now ?

  for i in range(1, bufcount)
    if bufexists(i) && getbufvar(i, "&mod") && bufname(i) != ""
      call go#util#EchoError("FAILED: ".bufname(i) . " has unsaved changes; please save before refactoring")
      return
    endif
  endfor

  if !exists("g:doctor_scope")
    let s:scope = ""
  else
    let s:scope = " -scope=".g:doctor_scope
  endif

  let file = printf(" -file=%s", cur_buf_file)

  if a:selected != -1
    let pos = printf(" -pos=%d,%d:%d,%d",
      \ line("'<"), col("'<"),
      \ line("'>"), col("'>"))
  else
    let pos = printf(" -pos=%d,%d:%d,%d",
      \ line('.'), col('.'),
      \ line('.'), col('.'))
  endif

  let bin_path = go#path#CheckBinPath(g:go_godoctor_bin)
  if empty(bin_path)
    return {'err': "bin path not found"}
  endif

  let cmd = printf('%s -v -w %s%s%s %s %s',
    \ bin_path,
    \ s:scope,
    \ file,
    \ pos,
    \ a:refac,
    \ join(map(copy(a:000), 'v:val'), ' '))

  " async blows up if shell escaped, yay
  let cmd = go#util#has_job() ? cmd : shellescape(cmd)

  " async support
  if go#util#has_job()
    call go#util#EchoProgress(printf("running '%s' refactoring...", a:refac))
    call s:refac_job({
          \ 'refac': a:refac,
          \ 'cmd': cmd,
          \})
    return
  endif

  " normal (non-async)
  let out = go#tool#ExecuteInDir(cmd)
  let splitted = split(out, '\n')
  call s:parse_errors(go#util#ShellError(), splitted)
endfun

func! s:refac_job(args)
  let messages = []
  func! s:callback(chan, msg) closure
    call add(messages, a:msg)
  endfunc

  let status_dir =  expand('%:p:h')

  func! s:close_cb(chan) closure
    let l:job = ch_getjob(a:chan)
    let l:info = job_info(l:job)

    let status = {
          \ 'desc': 'last status',
          \ 'type': a:args.refac,
          \ 'state': "finished",
          \ }

    if l:info.exitval
      let status.state = "failed"
    endif

    call go#statusline#Update(status_dir, status)

    call s:parse_errors(l:info.exitval, messages)
  endfunc

  let start_options = {
        \ 'callback': funcref("s:callback"),
        \ 'close_cb': funcref("s:close_cb"),
        \ }

  " modify GOPATH if needed
  let old_gopath = $GOPATH
  let $GOPATH = go#path#Detect()

  call go#statusline#Update(status_dir, {
        \ 'desc': "current status",
        \ 'type': a:args.refac,
        \ 'state': "started",
        \})

  call job_start(a:args.cmd, start_options)

  let $GOPATH = old_gopath
endfunc

func! s:parse_errors(exit_val, out)
  " reload all files to reflect the new changes. We explicitly call
  " checktime to trigger a reload of all files. See
  " http://www.mail-archive.com/vim@vim.org/msg05900.html for more info
  " about the autoread bug
  let current_autoread = &autoread
  set autoread
  silent! checktime
  let &autoread = current_autoread

  let l:listtype = "quickfix"
  if a:exit_val != 0
    call go#util#EchoError("FAILED")
    let errors = go#tool#ParseErrors(a:out)
    call go#list#Populate(l:listtype, errors, 'Refactor')
    call go#list#Window(l:listtype, len(errors))
    if !empty(errors)
      call go#list#JumpToFirst(l:listtype)
    elseif empty(errors)
      " failed to parse errors, output the original content
      call go#util#EchoError(join(a:out, ""))
    endif

    return
  endif

  " strip out newline on the end that godoctor puts. If we don't remove, it
  " will trigger the 'Hit ENTER to continue' prompt
  call go#list#Clean(l:listtype)
  call go#list#Window(l:listtype)
  call go#util#EchoSuccess(a:out[0])

  " refresh the buffer so we can see the new content
  " TODO(arslan): also find all other buffers and refresh them too. For this
  " we need a way to get the list of changes from godoctor upon an success
  " change.
  silent execute ":e"
endfunc

" vim:ts=2:sw=2:et
