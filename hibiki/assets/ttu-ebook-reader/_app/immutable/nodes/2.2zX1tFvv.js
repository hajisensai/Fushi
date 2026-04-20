import{n as d,s as l,b as p,v as u,d as o,c as f,f as h,g as b,i as m,K as g,x as r}from"../chunks/scheduler.1LdzKoqm.js";import{S as _,i as v}from"../chunks/index.yK_HZu36.js";import{g as $}from"../chunks/navigation.jUt-0FH4.js";import{l as x,m as y,p as P,t as E}from"../chunks/store.tYALZJpL.js";import{f as I}from"../chunks/format-page-title.XFnXHO7t.js";/**
 * @license BSD-3-Clause
 * Copyright (c) 2023, ッツ Reader Authors
 * All rights reserved.
 */function N(s,a){const e=a.subscribe();return{destroy:()=>e.unsubscribe()}}function S(s){let a,e,n,c;return document.title=I("Home"),{c(){a=l(),e=p("div")},l(t){u("svelte-1o30anf",document.head).forEach(o),a=f(t),e=h(t,"DIV",{}),b(e).forEach(o)},m(t,i){m(t,a,i),m(t,e,i),n||(c=g(N.call(null,e,s[0])),n=!0)},p:r,i:r,o:r,d(t){t&&(o(a),o(e)),n=!1,c()}}}function q(s){return[x.lastItem$.pipe(y(e=>e?`${P}/b?id=${e.dataId}`:"manage"),E($))]}class V extends _{constructor(a){super(),v(this,a,q,S,d,{})}}export{V as component};
