(function(){
  var d=document,rm=window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches;
  /* reveal on scroll */
  var els=[].slice.call(d.querySelectorAll('.rv'));
  if('IntersectionObserver' in window&&!rm){
    var io=new IntersectionObserver(function(es){es.forEach(function(e){if(e.isIntersecting){e.target.classList.add('in');io.unobserve(e.target)}})},{rootMargin:'0px 0px -8% 0px',threshold:.08});
    els.forEach(function(el,i){el.style.setProperty('--d',((i%3)*0.08)+'s');io.observe(el)});
  }else{els.forEach(function(el){el.classList.add('in')})}
  /* copy buttons */
  [].slice.call(d.querySelectorAll('.cb')).forEach(function(box){
    var pre=box.querySelector('pre');if(!pre)return;
    var b=d.createElement('button');b.type='button';b.className='copy';b.textContent='Copy';
    b.setAttribute('aria-label','Copy code to clipboard');
    b.addEventListener('click',function(){
      var t=pre.innerText.replace(/\s+$/,'');
      var done=function(){b.textContent='Copied';setTimeout(function(){b.textContent='Copy'},1600)};
      if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(done,function(){})}
      else{var ta=d.createElement('textarea');ta.value=t;d.body.appendChild(ta);ta.select();try{d.execCommand('copy');done()}catch(e){}d.body.removeChild(ta)}
    });
    box.appendChild(b);
  });
  /* keep SVG motion off for reduced motion users (CSS also handles it) */
  if(rm){[].slice.call(d.querySelectorAll('svg')).forEach(function(s){if(s.pauseAnimations)s.pauseAnimations()})}
})();
