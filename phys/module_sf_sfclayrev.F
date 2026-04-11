!=================================================================================================================
 module module_sf_sfclayrev
 use ccpp_kind_types,only: kind_phys
 use sf_sfclayrev,only: sf_sfclayrev_run


implicit none
private
public:: sfclayrev, sfclayrev_direct_surface_winds


 contains


!=================================================================================================================
subroutine sfclayrev(u3d,v3d,t3d,qv3d,p3d,dz8w,                    &
                      cp,g,rovcp,r,xlv,psfc,chs,chs2,cqs2,cpm,      &
                      znt,ust,pblh,mavail,zol,mol,regime,psim,psih, &
                      fm,fh,                                        &
                      xland,hfx,qfx,lh,tsk,flhc,flqc,qgh,qsfc,rmol, &
                      u10,v10,th2,t2,q2,                            &
                      gz1oz0,wspd,br,isfflx,dx,                     &
                      svp1,svp2,svp3,svpt0,ep1,ep2,                 &
                      karman,p1000mb,lakemask,                      &
                      ids,ide,jds,jde,kds,kde,                      &
                      ims,ime,jms,jme,kms,kme,                      &
                      its,ite,jts,jte,kts,kte,                      &
                      ustm,ck,cka,cd,cda,isftcflx,iz0tlnd,          &
                      shalwater_z0,water_depth,                     &
                      scm_force_flux,errmsg,errflg)
!=================================================================================================================
                                                               
!--- input arguments:
 integer,intent(in):: ids,ide,jds,jde,kds,kde, &
                      ims,ime,jms,jme,kms,kme, &
                      its,ite,jts,jte,kts,kte

integer,intent(in):: isfflx
integer,intent(in):: shalwater_z0
integer,intent(in),optional:: isftcflx, iz0tlnd
integer,intent(in),optional:: scm_force_flux

real(kind=kind_phys),intent(in):: svp1,svp2,svp3,svpt0
real(kind=kind_phys),intent(in):: ep1,ep2,karman
real(kind=kind_phys),intent(in):: p1000mb
real(kind=kind_phys),intent(in):: cp,g,rovcp,r,xlv

real(kind=kind_phys),intent(in),dimension(ims:ime,jms:jme):: &
    dx,         &
    mavail,     &
    pblh,       &
    psfc,       &
    tsk,        &
    xland,      &
    lakemask,   &
    water_depth

real(kind=kind_phys),intent(in),dimension(ims:ime,kms:kme,jms:jme):: &
    dz8w,       &
    qv3d,       &
    p3d,        &
    t3d,        &
    u3d,        &
    v3d

!--- output arguments:
 character(len=*),intent(out):: errmsg
 integer,intent(out):: errflg

 real(kind=kind_phys),intent(out),dimension(ims:ime,jms:jme):: &
    lh,         &
    u10,        &
    v10,        &
    th2,        &
    t2,         &
    q2

 real(kind=kind_phys),intent(out),dimension(ims:ime,jms:jme),optional:: &
    ck,         &
    cka,        &
    cd,         &
    cda

!--- inout arguments:
 real(kind=kind_phys),intent(inout),dimension(ims:ime,jms:jme):: &
    regime,     &
    hfx,        &
    qfx,        &
    qsfc,       &
    mol,        &
    rmol,       &
    gz1oz0,     &
    wspd,       &
    br,         &
    psim,       &
    psih,       &
    fm,         &
    fh,         &
    znt,        &
    zol,        &
    ust,        &
    cpm,        &
    chs2,       &
    cqs2,       &
    chs,        &
    flhc,       &
    flqc,       &
    qgh

 real(kind=kind_phys),intent(inout),dimension(ims:ime,jms:jme),optional:: &
    ustm

!--- local variables and arrays:
 logical:: l_isfflx
 logical:: l_shalwater_z0
 logical:: l_scm_force_flux

integer:: i,j
real(kind=kind_phys),dimension(its:ite):: &
    ck_hv,cka_hv,cd_hv,cda_hv

real(kind=kind_phys),dimension(its:ite):: &
    ustm_hv

!-----------------------------------------------------------------------------------------------------------------

 l_isfflx         = .false.
 l_shalwater_z0   = .false.
 l_scm_force_flux = .false.
 if(isfflx .eq. 1) l_isfflx = .true.
 if(shalwater_z0 .eq. 1) l_shalwater_z0 = .true.
 if(scm_force_flux .eq. 1) l_scm_force_flux = .true.

 do j = jts,jte

    if(present(ustm)) then
       !!$acc parallel loop
       do i = its,ite
          ustm_hv(i) = ustm(i,j)
       enddo
    endif

    call sf_sfclayrev_run(ux=u3d(its:ite,kts,j),vx=v3d(its:ite,kts,j),      &
                          t1d=t3d(its:ite,kts,j),qv1d=qv3d(its:ite,kts,j),   &
                          p1d=p3d(its:ite,kts,j),dz8w1d=dz8w(its:ite,kts,j), &
                          cp=cp,g=g,rovcp=rovcp,r=r,xlv=xlv,                  &
                          psfcpa=psfc(its:ite,j),chs=chs(its:ite,j),          &
                          chs2=chs2(its:ite,j),cqs2=cqs2(its:ite,j),          &
                          cpm=cpm(its:ite,j),pblh=pblh(its:ite,j),            &
                          rmol=rmol(its:ite,j),znt=znt(its:ite,j),            &
                          ust=ust(its:ite,j),mavail=mavail(its:ite,j),        &
                          zol=zol(its:ite,j),mol=mol(its:ite,j),              &
                          regime=regime(its:ite,j),psim=psim(its:ite,j),      &
                          psih=psih(its:ite,j),fm=fm(its:ite,j),              &
                          fh=fh(its:ite,j),xland=xland(its:ite,j),            &
                          lakemask=lakemask(its:ite,j),hfx=hfx(its:ite,j),    &
                          qfx=qfx(its:ite,j),tsk=tsk(its:ite,j),              &
                          u10=u10(its:ite,j),v10=v10(its:ite,j),              &
                          th2=th2(its:ite,j),t2=t2(its:ite,j),q2=q2(its:ite,j),&
                          flhc=flhc(its:ite,j),flqc=flqc(its:ite,j),          &
                          qgh=qgh(its:ite,j),qsfc=qsfc(its:ite,j),            &
                          lh=lh(its:ite,j),gz1oz0=gz1oz0(its:ite,j),          &
                          wspd=wspd(its:ite,j),br=br(its:ite,j),              &
                          isfflx=l_isfflx,dx=dx(its:ite,j),                   &
                          svp1=svp1,svp2=svp2,svp3=svp3,svpt0=svpt0,          &
                          ep1=ep1,ep2=ep2,karman=karman,                      &
                          p1000mb=p1000mb,shalwater_z0=l_shalwater_z0,        &
                          water_depth=water_depth(its:ite,j),                 &
                          its=its,ite=ite,errmsg=errmsg,errflg=errflg         &
#if ( ( EM_CORE == 1 ) || ( defined(mpas) ) )
                          ,isftcflx=isftcflx,iz0tlnd=iz0tlnd,scm_force_flux=l_scm_force_flux,      &
                          ustm=ustm_hv,ck=ck_hv,cka=cka_hv,cd=cd_hv,cda=cda_hv                     &
#endif
                         )

    if(present(ck) .and. present(cka) .and. present(cd) .and. present(cda)) then
       !!$acc parallel loop
       do i = its,ite
          ck(i,j)  = ck_hv(i)
          cka(i,j) = cka_hv(i)
          cd(i,j)  = cd_hv(i)
          cda(i,j) = cda_hv(i)
       enddo
    endif

    if(present(ustm)) then
       !!$acc parallel loop
       do i = its,ite
          ustm(i,j) = ustm_hv(i)
       enddo
    endif

 enddo

 end subroutine sfclayrev

!=================================================================================================================
subroutine sfclayrev_direct_surface_winds(u3d,v3d,t3d,qv3d,p3d,dz8w,        &
                      cp,g,rovcp,r,xlv,psfc,chs,chs2,cqs2,cpm,              &
                      znt,ust,pblh,mavail,zol,mol,regime,psim,psih,         &
                      fm,fh,                                                &
                      xland,hfx,qfx,lh,tsk,flhc,flqc,qgh,qsfc,rmol,         &
                      u10,v10,th2,t2,q2,                                    &
                      gz1oz0,wspd,br,isfflx,dx,                             &
                      svp1,svp2,svp3,svpt0,ep1,ep2,                         &
                      karman,p1000mb,lakemask,uoce,voce,u_frame,v_frame,    &
                      ids,ide,jds,jde,kds,kde,                              &
                      ims,ime,jms,jme,kms,kme,                              &
                      its,ite,jts,jte,kts,kte,                              &
                      ustm,ck,cka,cd,cda,isftcflx,iz0tlnd,                  &
                      shalwater_z0,water_depth,                             &
                      scm_force_flux,errmsg,errflg)
!=================================================================================================================

!--- input arguments:
 integer,intent(in):: ids,ide,jds,jde,kds,kde, &
                      ims,ime,jms,jme,kms,kme, &
                      its,ite,jts,jte,kts,kte

 integer,intent(in):: isfflx
 integer,intent(in):: shalwater_z0
 integer,intent(in),optional:: isftcflx, iz0tlnd
 integer,intent(in),optional:: scm_force_flux

 real(kind=kind_phys),intent(in):: svp1,svp2,svp3,svpt0
 real(kind=kind_phys),intent(in):: ep1,ep2,karman
 real(kind=kind_phys),intent(in):: p1000mb
 real(kind=kind_phys),intent(in):: cp,g,rovcp,r,xlv
 real(kind=kind_phys),intent(in):: u_frame,v_frame

 real(kind=kind_phys),intent(in),dimension(ims:ime,jms:jme):: &
    dx,         &
    mavail,     &
    pblh,       &
    psfc,       &
    tsk,        &
    xland,      &
    lakemask,   &
    water_depth,&
    uoce,       &
    voce

 real(kind=kind_phys),intent(in),dimension(ims:ime,kms:kme,jms:jme):: &
    dz8w,       &
    qv3d,       &
    p3d,        &
    t3d,        &
    u3d,        &
    v3d

!--- output arguments:
 character(len=*),intent(out):: errmsg
 integer,intent(out):: errflg

 real(kind=kind_phys),intent(out),dimension(ims:ime,jms:jme):: &
    lh,         &
    u10,        &
    v10,        &
    th2,        &
    t2,         &
    q2

 real(kind=kind_phys),intent(out),dimension(ims:ime,jms:jme),optional:: &
    ck,         &
    cka,        &
    cd,         &
    cda

!--- inout arguments:
 real(kind=kind_phys),intent(inout),dimension(ims:ime,jms:jme):: &
    regime,     &
    hfx,        &
    qfx,        &
    qsfc,       &
    mol,        &
    rmol,       &
    gz1oz0,     &
    wspd,       &
    br,         &
    psim,       &
    psih,       &
    fm,         &
    fh,         &
    znt,        &
    zol,        &
    ust,        &
    cpm,        &
    chs2,       &
    cqs2,       &
    chs,        &
    flhc,       &
    flqc,       &
    qgh

 real(kind=kind_phys),intent(inout),dimension(ims:ime,jms:jme),optional:: &
    ustm

!--- local variables and arrays:
 logical:: l_isfflx
 logical:: l_shalwater_z0
 logical:: l_scm_force_flux

 integer:: i,j
 real(kind=kind_phys),dimension(its:ite):: &
    ux_hv,vx_hv,ck_hv,cka_hv,cd_hv,cda_hv

 real(kind=kind_phys),dimension(its:ite):: &
    ustm_hv

!-----------------------------------------------------------------------------------------------------------------

 l_isfflx         = .false.
 l_shalwater_z0   = .false.
 l_scm_force_flux = .false.
 if(isfflx .eq. 1) l_isfflx = .true.
 if(shalwater_z0 .eq. 1) l_shalwater_z0 = .true.
 if(scm_force_flux .eq. 1) l_scm_force_flux = .true.

 do j = jts,jte

    do i = its,ite
       ux_hv(i) = u3d(i,kts,j) + u_frame - uoce(i,j)
       vx_hv(i) = v3d(i,kts,j) + v_frame - voce(i,j)
    enddo

    if(present(ustm)) then
       !!$acc parallel loop
       do i = its,ite
          ustm_hv(i) = ustm(i,j)
       enddo
    endif

    call sf_sfclayrev_run(ux=ux_hv,vx=vx_hv,                                &
                          t1d=t3d(its:ite,kts,j),qv1d=qv3d(its:ite,kts,j),   &
                          p1d=p3d(its:ite,kts,j),dz8w1d=dz8w(its:ite,kts,j), &
                          cp=cp,g=g,rovcp=rovcp,r=r,xlv=xlv,                  &
                          psfcpa=psfc(its:ite,j),chs=chs(its:ite,j),          &
                          chs2=chs2(its:ite,j),cqs2=cqs2(its:ite,j),          &
                          cpm=cpm(its:ite,j),pblh=pblh(its:ite,j),            &
                          rmol=rmol(its:ite,j),znt=znt(its:ite,j),            &
                          ust=ust(its:ite,j),mavail=mavail(its:ite,j),        &
                          zol=zol(its:ite,j),mol=mol(its:ite,j),              &
                          regime=regime(its:ite,j),psim=psim(its:ite,j),      &
                          psih=psih(its:ite,j),fm=fm(its:ite,j),              &
                          fh=fh(its:ite,j),xland=xland(its:ite,j),            &
                          lakemask=lakemask(its:ite,j),hfx=hfx(its:ite,j),    &
                          qfx=qfx(its:ite,j),tsk=tsk(its:ite,j),              &
                          u10=u10(its:ite,j),v10=v10(its:ite,j),              &
                          th2=th2(its:ite,j),t2=t2(its:ite,j),q2=q2(its:ite,j),&
                          flhc=flhc(its:ite,j),flqc=flqc(its:ite,j),          &
                          qgh=qgh(its:ite,j),qsfc=qsfc(its:ite,j),            &
                          lh=lh(its:ite,j),gz1oz0=gz1oz0(its:ite,j),          &
                          wspd=wspd(its:ite,j),br=br(its:ite,j),              &
                          isfflx=l_isfflx,dx=dx(its:ite,j),                   &
                          svp1=svp1,svp2=svp2,svp3=svp3,svpt0=svpt0,          &
                          ep1=ep1,ep2=ep2,karman=karman,                      &
                          p1000mb=p1000mb,shalwater_z0=l_shalwater_z0,        &
                          water_depth=water_depth(its:ite,j),                 &
                          its=its,ite=ite,errmsg=errmsg,errflg=errflg         &
#if ( ( EM_CORE == 1 ) || ( defined(mpas) ) )
                          ,isftcflx=isftcflx,iz0tlnd=iz0tlnd,scm_force_flux=l_scm_force_flux,      &
                          ustm=ustm_hv,ck=ck_hv,cka=cka_hv,cd=cd_hv,cda=cda_hv                     &
#endif
                         )

    if(present(ck) .and. present(cka) .and. present(cd) .and. present(cda)) then
       !!$acc parallel loop
       do i = its,ite
          ck(i,j)  = ck_hv(i)
          cka(i,j) = cka_hv(i)
          cd(i,j)  = cd_hv(i)
          cda(i,j) = cda_hv(i)
       enddo
    endif

    if(present(ustm)) then
       !!$acc parallel loop
       do i = its,ite
          ustm(i,j) = ustm_hv(i)
       enddo
    endif

 enddo

 end subroutine sfclayrev_direct_surface_winds

!=================================================================================================================
 end module module_sf_sfclayrev
!=================================================================================================================
