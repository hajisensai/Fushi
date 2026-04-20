import{p as r}from"./error-handler.2V3Bl3DC.js";import{m as s,A as i}from"./store.tYALZJpL.js";import{a4 as n,a5 as l,o as c,a6 as u,G as I,a7 as m,a8 as d,a9 as p,aa as E}from"./fa.RWUnZmg3.js";/**
 * @license BSD-3-Clause
 * Copyright (c) 2023, ッツ Reader Authors
 * All rights reserved.
 */function T(){return r(s(()=>""),i((t,a)=>!a))}/**
 * @license BSD-3-Clause
 * Copyright (c) 2023, ッツ Reader Authors
 * All rights reserved.
 */const O="ttsu:page.change",P="ttsu:close:popover";/**
 * @license BSD-3-Clause
 * Copyright (c) 2023, ッツ Reader Authors
 * All rights reserved.
 */function R(t,a){const o=e=>{!e.defaultPrevented&&!t.contains(e.target)&&a(e)};return document.addEventListener("click",o,!0),{destroy(){document.removeEventListener("click",o,!0)}}}/**
 * @license BSD-3-Clause
 * Copyright (c) 2023, ッツ Reader Authors
 * All rights reserved.
 */const S={MANAGE:{routeId:"/manage",label:"Manager",icon:n},SETTINGS:{routeId:"/settings",label:"Settings",icon:l},STATISTICS:{routeId:"/statistics",label:"Statistics",icon:c},READER_IMAGE_GALLERY:{routeId:"",label:"Images",icon:u},DOMAIN_HINT:{routeId:"",label:"Domain Hint",icon:I},BUG_REPORT:{routeId:"",label:"Bug Report",icon:m},FOLDER_IMPORT:{routeId:"",label:"Import Folder(s)",icon:d},FILE_IMPORT:{routeId:"",label:"Import File(s)",icon:p},BACKUP_IMPORT:{routeId:"",label:"Import Backup",icon:E}};export{P as C,O as P,R as c,S as m,T as r};
