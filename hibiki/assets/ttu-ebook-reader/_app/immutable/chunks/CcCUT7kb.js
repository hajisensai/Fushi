import{p as s}from"./DAsXJTJX.js";import{m as i,h as r}from"./BfJHwf5j.js";import{d as n,e as l,g as c,h as u,i as I,j as m,k as d,l as p,m as E,n as g}from"./iaG4sGDw.js";/**
 * @license BSD-3-Clause
 * Copyright (c) 2026, ッツ Reader Authors
 * All rights reserved.
 */function T(){return s(i(()=>""),r((a,t)=>!t))}/**
 * @license BSD-3-Clause
 * Copyright (c) 2026, ッツ Reader Authors
 * All rights reserved.
 */const P="ttsu:skipKeyListener",R="ttsu:synced",_="ttsu:db.version",A="ttsu:section.change",b="ttsu:page.change",G="ttsu:close:popover";/**
 * @license BSD-3-Clause
 * Copyright (c) 2026, ッツ Reader Authors
 * All rights reserved.
 */const N={MANAGE:{routeId:"/manage",label:"Manager",icon:n,title:"Go to Book Manager"},SETTINGS:{routeId:"/settings",label:"Settings",icon:l,title:"Go to Reader Settings"},STATISTICS:{routeId:"/statistics",label:"Statistics",icon:c,title:"Go to Statistics"},JUMP_TO_POSITION:{routeId:"",label:"Jump",icon:u,title:"Jump to Position"},READER_IMAGE_GALLERY:{routeId:"",label:"Images",icon:I,title:"Open Image Gallery"},DOMAIN_HINT:{routeId:"",label:"Domain Hint",icon:m,title:"Old Domain used"},BUG_REPORT:{routeId:"",label:"Bug Report",icon:d,title:"Report an Issue"},FOLDER_IMPORT:{routeId:"",label:"Import Folder(s)",icon:p,title:"Import from Folder"},FILE_IMPORT:{routeId:"",label:"Import File(s)",icon:E,title:"Import Files"},BACKUP_IMPORT:{routeId:"",label:"Import Backup",icon:g,title:"Import Backup"}};/**
 * @license BSD-3-Clause
 * Copyright (c) 2026, ッツ Reader Authors
 * All rights reserved.
 */function C(a,t){const o=e=>{!e.defaultPrevented&&!a.contains(e.target)&&t(e)};return document.addEventListener("click",o,!0),{destroy(){document.removeEventListener("click",o,!0)}}}export{G as C,_ as D,b as P,A as S,R as a,P as b,C as c,N as m,T as r};
