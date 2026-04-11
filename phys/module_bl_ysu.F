#define NEED_B4B_DURING_CCPP_TESTING 1
!=================================================================================================================
 module module_bl_ysu
 use ccpp_kind_types,only: kind_phys
 use bl_ysu


 implicit none
 private
 public:: ysu

#if defined(WRF_OPENACC_USE_ACCEL_LIB)
! Wrapper-only OpenACC here just stages data movement around a CPU-owned YSU
! solve. Keep it disabled until the surface/PBL fast path is redesigned as a
! single ownership region.
#define WRF_ACC_PARALLEL_LOOP
#define WRF_ACC_PARALLEL_LOOP_COLLAPSE_2
#else
#define WRF_ACC_PARALLEL_LOOP
#define WRF_ACC_PARALLEL_LOOP_COLLAPSE_2
#endif


 contains


!=================================================================================================================
   subroutine ysu(u3d,v3d,t3d,qv3d,qc3d,qi3d,p3d,p3di,pi3d,                    &
                  rublten,rvblten,rthblten,                                    &
                  rqvblten,rqcblten,rqiblten,flag_qc,flag_qi,                  &
                  cp,g,rovcp,rd,rovg,ep1,ep2,karman,xlv,rv,                    &
                  dz8w,psfc,                                                   &
                  znt,ust,hpbl,psim,psih,                                      &
                  xland,hfx,qfx,wspd,br,                                       &
                  dt,kpbl2d,                                                   &
                  exch_h,exch_m,                                               &
                  wstar,delta,                                                 &
                  u10,v10,                                                     &
                  uoce,voce,                                                   &
                  rthraten,ysu_topdown_pblmix,                                 &
                  ctopo,ctopo2,                                                &
                  idiff,flag_bep,frc_urb2d,                                    &
                  a_u_bep,a_v_bep,a_t_bep,                                     &
                  a_q_bep,                                                     &
                  a_e_bep,b_u_bep,b_v_bep,                                     &
                  b_t_bep,b_q_bep,                                             &
                  b_e_bep,dlg_bep,                                             &
                  dl_u_bep,sf_bep,vl_bep,                                      &
                  ids,ide, jds,jde, kds,kde,                                   &
                  ims,ime, jms,jme, kms,kme,                                   &
                  its,ite, jts,jte, kts,kte,                                   &
                  errmsg,errflg                                                &
                 )
!-------------------------------------------------------------------------------
  implicit none
!-------------------------------------------------------------------------------
!-- u3d         3d u-velocity interpolated to theta points (m/s)
!-- v3d         3d v-velocity interpolated to theta points (m/s)
!-- th3d        3d potential temperature (k)
!-- t3d         temperature (k)
!-- qv3d        3d water vapor mixing ratio (kg/kg)
!-- qc3d        3d cloud mixing ratio (kg/kg)
!-- qi3d        3d ice mixing ratio (kg/kg)
!               (note: if P_QI<PARAM_FIRST_SCALAR this should be zero filled)
!-- p3d         3d pressure (pa)
!-- p3di        3d pressure (pa) at interface level
!-- pi3d        3d exner function (dimensionless)
!-- rr3d        3d dry air density (kg/m^3)
!-- rublten     u tendency due to
!               pbl parameterization (m/s/s)
!-- rvblten     v tendency due to
!               pbl parameterization (m/s/s)
!-- rthblten    theta tendency due to
!               pbl parameterization (K/s)
!-- rqvblten    qv tendency due to
!               pbl parameterization (kg/kg/s)
!-- rqcblten    qc tendency due to
!               pbl parameterization (kg/kg/s)
!-- rqiblten    qi tendency due to
!               pbl parameterization (kg/kg/s)
!-- cp          heat capacity at constant pressure for dry air (j/kg/k)
!-- g           acceleration due to gravity (m/s^2)
!-- rovcp       r/cp
!-- rd          gas constant for dry air (j/kg/k)
!-- rovg        r/g
!-- dz8w        dz between full levels (m)
!-- xlv         latent heat of vaporization (j/kg)
!-- rv          gas constant for water vapor (j/kg/k)
!-- psfc        pressure at the surface (pa)
!-- znt         roughness length (m)
!-- ust         u* in similarity theory (m/s)
!-- hpbl        pbl height (m)
!-- psim        similarity stability function for momentum
!-- psih        similarity stability function for heat
!-- xland       land mask (1 for land, 2 for water)
!-- hfx         upward heat flux at the surface (w/m^2)
!-- qfx         upward moisture flux at the surface (kg/m^2/s)
!-- wspd        wind speed at lowest model level (m/s)
!-- u10         u-wind speed at 10 m (m/s)
!-- v10         v-wind speed at 10 m (m/s)
!-- uoce        sea surface zonal currents (m s-1)
!-- voce        sea surface meridional currents (m s-1)
!-- br          bulk richardson number in surface layer
!-- dt          time step (s)
!-- rvovrd      r_v divided by r_d (dimensionless)
!-- ep1         constant for virtual temperature (r_v/r_d - 1)
!-- ep2         constant for specific humidity calculation
!-- karman      von karman constant
!-- idiff       diff3d BEP/BEM+BEM diffusion flag
!-- flag_bep    flag to use BEP/BEP+BEM
!-- frc_urb2d   urban fraction
!-- a_u_bep     BEP/BEP+BEM implicit component u-mom
!-- a_v_bep     BEP/BEP+BEM implicit component v-mom
!-- a_t_bep     BEP/BEP+BEM implicit component pot. temp.
!-- a_q_bep     BEP/BEP+BEM implicit component vapor mixing ratio
!-- a_e_bep     BEP/BEP+BEM implicit component TKE
!-- b_u_bep     BEP/BEP+BEM explicit component u-mom
!-- b_v_bep     BEP/BEP+BEM explicit component v-mom
!-- b_t_bep     BEP/BEP+BEM explicit component pot.temp.
!-- b_q_bep     BEP/BEP+BEM explicit component vapor mixing ratio
!-- b_e_bep     BEP/BEP+BEM explicit component TKE
!-- dlg_bep     Height above ground Martilli et al. (2002) Eq. 24
!-- dl_u_bep    modified length scale Martilli et al. (2002) Eq. 22
!-- sf_bep      fraction of vertical surface not occupied by buildings
!-- vl_bep      volume fraction of grid cell not occupied by buildings
!-- ids         start index for i in domain
!-- ide         end index for i in domain
!-- jds         start index for j in domain
!-- jde         end index for j in domain
!-- kds         start index for k in domain
!-- kde         end index for k in domain
!-- ims         start index for i in memory
!-- ime         end index for i in memory
!-- jms         start index for j in memory
!-- jme         end index for j in memory
!-- kms         start index for k in memory
!-- kme         end index for k in memory
!-- its         start index for i in tile
!-- ite         end index for i in tile
!-- jts         start index for j in tile
!-- jte         end index for j in tile
!-- kts         start index for k in tile
!-- kte         end index for k in tile
!-------------------------------------------------------------------------------
!
!
   integer,  intent(in   )   ::      ids,ide, jds,jde, kds,kde,                &
                                     ims,ime, jms,jme, kms,kme,                &
                                     its,ite, jts,jte, kts,kte

   integer,  intent(in)      ::      ysu_topdown_pblmix
!
   real(kind=kind_phys),     intent(in   )   ::      dt,cp,g,rovcp,rovg,rd,xlv,rv
!
   real(kind=kind_phys),     intent(in )     ::      ep1,ep2,karman
!
   real(kind=kind_phys),     dimension( ims:ime, kms:kme, jms:jme )          , &
             intent(in   )   ::                                          qv3d, &
                                                                         qc3d, &
                                                                         qi3d, &
                                                                          p3d, &
                                                                         pi3d, &
                                                                          t3d, &
                                                                         dz8w, &
                                                                     rthraten
   real(kind=kind_phys),     dimension( ims:ime, kms:kme, jms:jme )          , &
             intent(in   )   ::                                          p3di
!
   real(kind=kind_phys),     dimension( ims:ime, kms:kme, jms:jme )          , &
             intent(out  )   ::                                       rublten, &
                                                                      rvblten, &
                                                                     rthblten, &
                                                                     rqvblten, &
                                                                     rqcblten, &
                                                                     rqiblten
!
   real(kind=kind_phys),     dimension( ims:ime, kms:kme, jms:jme )          , &
             intent(out  )   ::                                        exch_h, &
                                                                       exch_m
   real(kind=kind_phys),     dimension( ims:ime, jms:jme )                   , &
             intent(out  )   ::                                         wstar
   real(kind=kind_phys),     dimension( ims:ime, jms:jme )                   , &
             intent(out  )   ::                                         delta
   real(kind=kind_phys),     dimension( ims:ime, jms:jme )                   , &
             intent(inout)   ::                                           u10, &
                                                                          v10
   real(kind=kind_phys),     dimension( ims:ime, jms:jme )                   , &
             intent(in   )   ::                                          uoce, &
                                                                         voce
!
   real(kind=kind_phys),     dimension( ims:ime, jms:jme )                   , &
             intent(in   )   ::                                         xland, &
                                                                          hfx, &
                                                                          qfx, &
                                                                           br, &
                                                                         psfc
   real(kind=kind_phys),     dimension( ims:ime, jms:jme )                   , &
             intent(in   )   ::                                                &
                                                                         psim, &
                                                                         psih
   real(kind=kind_phys),     dimension( ims:ime, jms:jme )                   , &
             intent(in   )   ::                                           znt, &
                                                                          ust, &
                                                                          wspd
   real(kind=kind_phys),     dimension( ims:ime, jms:jme )                   , &
             intent(out  )   ::                                          hpbl
!
   real(kind=kind_phys),     dimension( ims:ime, kms:kme, jms:jme )          , &
             intent(in   )   ::                                           u3d, &
                                                                          v3d
!
   integer,  dimension( ims:ime, jms:jme )                                   , &
             intent(out  )   ::                                        kpbl2d
!
   logical,  intent(in)      ::                                       flag_qc, &
                                                                      flag_qi
!
   integer,  intent(in)      ::                                          idiff
   logical,  intent(in)      ::                                       flag_bep
   real(kind=kind_phys),     dimension( ims:ime, kms:kme, jms:jme )          , &
             optional                                                        , &
             intent(in)      ::                                       a_u_bep, &
                                                              a_v_bep,a_t_bep, &
                                                              a_e_bep,b_u_bep, &
                                                              a_q_bep,b_q_bep, &
                                                              b_v_bep,b_t_bep, &
                                                              b_e_bep,dlg_bep, &
                                                                     dl_u_bep, &
                                                                vl_bep,sf_bep
   real(kind=kind_phys),     dimension(ims:ime,jms:jme)                      , &
             optional                                                        , &
             intent(in)      ::                                     frc_urb2d
!
   real(kind=kind_phys),     dimension( ims:ime, jms:jme )                   , &
             optional                                                        , &
             intent(in   )   ::                                         ctopo, &
                                                                       ctopo2
!
   character(len=*), intent(out)   ::                                  errmsg
   integer,          intent(out)   ::                                  errflg
!local
   integer ::  i,j,k

!temporary allocation of local chemical species and/or passive tracers that are vertically-
!mixed in subroutine bl_ysu_run:
   logical:: l_topdown_pblmix

   integer,  parameter :: nmix = 0
   integer :: n

   real(kind=kind_phys),   dimension(ims:ime,kms:kme,jms:jme,nmix)::       qmix
   real(kind=kind_phys),   dimension(ims:ime,kms:kme,jms:jme,nmix):: rqmixblten

   !  Local tile-sized arrays for contiguous data for bl_ysu_run call.

   real(kind=kind_phys),   dimension(its:ite,kts:kte,nmix) ::              &
                                                             qmix_hv     , &
                                                             rqmixblten_hv

   real(kind=kind_phys),   dimension(its:ite,kts:kte)      ::              &
                                                             a_u_hv      , &
                                                             a_v_hv      , &
                                                             a_t_hv      , &
                                                             a_e_hv      , &
                                                             b_u_hv      , &
                                                             a_q_hv      , &
                                                             b_q_hv      , &
                                                             b_v_hv      , &
                                                             b_t_hv      , &
                                                             b_e_hv      , &
                                                             dlg_hv      , &
                                                             dl_u_hv     , &
                                                             vlk_hv      , &
                                                             sfk_hv

   real,                   dimension(its:ite)              ::              &
                                                             frcurb_hv

!-----------------------------------------------------------------------------------------------------------------

   l_topdown_pblmix = .false.
   if(ysu_topdown_pblmix .eq. 1) l_topdown_pblmix = .true.

   do j = jts,jte
      if(.not. flag_bep) then
         call bl_ysu_run(ux=u3d(its:ite,kts:kte,j),vx=v3d(its:ite,kts:kte,j)         &
                 ,tx=t3d(its:ite,kts:kte,j)                                          &
                 ,qvx=qv3d(its:ite,kts:kte,j)                                        &
                 ,qcx=qc3d(its:ite,kts:kte,j),qix=qi3d(its:ite,kts:kte,j)            &
                 ,f_qc=flag_qc,f_qi=flag_qi                                           &
                 ,nmix=nmix,qmix=qmix_hv                                              &
                 ,p2d=p3d(its:ite,kts:kte,j),p2di=p3di(its:ite,kts:kte+1,j)          &
                 ,pi2d=pi3d(its:ite,kts:kte,j)                                        &
                 ,utnp=rublten(its:ite,kts:kte,j),vtnp=rvblten(its:ite,kts:kte,j)     &
                 ,ttnp=rthblten(its:ite,kts:kte,j)                                    &
                 ,qvtnp=rqvblten(its:ite,kts:kte,j)                                   &
                 ,qctnp=rqcblten(its:ite,kts:kte,j)                                   &
                 ,qitnp=rqiblten(its:ite,kts:kte,j)                                   &
                 ,qmixtnp=rqmixblten_hv                                               &
                 ,cp=cp,g=g,rovcp=rovcp,rd=rd,rovg=rovg                               &
                 ,xlv=xlv,rv=rv                                                       &
                 ,ep1=ep1,ep2=ep2,karman=karman                                       &
                 ,dz8w2d=dz8w(its:ite,kts:kte,j)                                      &
                 ,psfcpa=psfc(its:ite,j),znt=znt(its:ite,j),ust=ust(its:ite,j)       &
                 ,hpbl=hpbl(its:ite,j)                                                &
                 ,psim=psim(its:ite,j),psih=psih(its:ite,j)                           &
                 ,xland=xland(its:ite,j),hfx=hfx(its:ite,j),qfx=qfx(its:ite,j)       &
                 ,wspd=wspd(its:ite,j),br=br(its:ite,j)                               &
                 ,dt=dt,kpbl1d=kpbl2d(its:ite,j)                                      &
                 ,exch_hx=exch_h(its:ite,kts:kte,j)                                   &
                 ,exch_mx=exch_m(its:ite,kts:kte,j)                                   &
                 ,wstar=wstar(its:ite,j),delta=delta(its:ite,j)                       &
                 ,u10=u10(its:ite,j),v10=v10(its:ite,j)                               &
                 ,uox=uoce(its:ite,j),vox=voce(its:ite,j)                             &
                 ,rthraten=rthraten(its:ite,kts:kte,j)                                &
                 ,ysu_topdown_pblmix=l_topdown_pblmix                                 &
                 ,ctopo=ctopo(its:ite,j),ctopo2=ctopo2(its:ite,j)                     &
                 ,flag_bep=flag_bep                                                   &
                 ,its=its,ite=ite,kte=kte,kme=kme                                     &
                 ,errmsg=errmsg,errflg=errflg                                         )
#if (NEED_B4B_DURING_CCPP_TESTING == 1)
         WRF_ACC_PARALLEL_LOOP_COLLAPSE_2
         do k = kts, kte
            do i = its, ite
               rthblten(i,k,j) = rthblten(i,k,j) / pi3d(i,k,j)
            end do
         end do
#endif
      else
!
         !  Assign input data to local tile-sized arrays for the urban/BEP path.

         do n = 1, nmix
            WRF_ACC_PARALLEL_LOOP_COLLAPSE_2
            do k = kts, kte
               do i = its, ite
                  qmix_hv(i,k,n) = qmix(i,k,j,n)
               end do
            end do
         end do

         if(present(a_u_bep) .and. present(a_v_bep) .and. present(a_t_bep) .and.  &
            present(a_q_bep) .and. present(a_e_bep) .and. present(b_u_bep) .and.  &
            present(b_v_bep) .and. present(b_t_bep) .and. present(b_q_bep) .and.  &
            present(b_e_bep) .and. present(dlg_bep) .and. present(dl_u_bep) .and. &
            present(sf_bep)  .and. present(vl_bep)  .and. present(frc_urb2d)) then

            ! following v4.5 logic to fix access violation
            WRF_ACC_PARALLEL_LOOP_COLLAPSE_2
            do k = kts, kte
               do i = its,ite
                  a_u_hv(i,k)  = a_u_bep(i,k,j)
                  a_v_hv(i,k)  = a_v_bep(i,k,j)
                  a_t_hv(i,k)  = a_t_bep(i,k,j)
                  a_q_hv(i,k)  = a_q_bep(i,k,j)
                  a_e_hv(i,k)  = a_e_bep(i,k,j)
                  b_u_hv(i,k)  = b_u_bep(i,k,j)
                  b_v_hv(i,k)  = b_v_bep(i,k,j)
                  b_t_hv(i,k)  = b_t_bep(i,k,j)
                  b_q_hv(i,k)  = b_q_bep(i,k,j)
                  b_e_hv(i,k)  = b_e_bep(i,k,j)
                  dlg_hv(i,k)  = dlg_bep(i,k,j)
                  dl_u_hv(i,k) = dl_u_bep(i,k,j)
                  vlk_hv(i,k) = vl_bep(i,k,j)
                  sfk_hv(i,k)  = sf_bep(i,k,j)
               enddo
            enddo
            WRF_ACC_PARALLEL_LOOP
            do i = its, ite
               frcurb_hv(i) = frc_urb2d(i,j)
            enddo
         endif
!
         call bl_ysu_run(ux=u3d(its:ite,kts:kte,j),vx=v3d(its:ite,kts:kte,j)     &
                 ,tx=t3d(its:ite,kts:kte,j)                                       &
                 ,qvx=qv3d(its:ite,kts:kte,j)                                     &
                 ,qcx=qc3d(its:ite,kts:kte,j),qix=qi3d(its:ite,kts:kte,j)         &
                 ,f_qc=flag_qc,f_qi=flag_qi                                       &
                 ,nmix=nmix,qmix=qmix_hv                                          &
                 ,p2d=p3d(its:ite,kts:kte,j),p2di=p3di(its:ite,kts:kte+1,j)      &
                 ,pi2d=pi3d(its:ite,kts:kte,j)                                    &
                 ,utnp=rublten(its:ite,kts:kte,j)                                 &
                 ,vtnp=rvblten(its:ite,kts:kte,j)                                 &
                 ,ttnp=rthblten(its:ite,kts:kte,j)                                &
                 ,qvtnp=rqvblten(its:ite,kts:kte,j)                               &
                 ,qctnp=rqcblten(its:ite,kts:kte,j)                               &
                 ,qitnp=rqiblten(its:ite,kts:kte,j)                               &
                 ,qmixtnp=rqmixblten_hv                                           &
                 ,cp=cp,g=g,rovcp=rovcp,rd=rd,rovg=rovg                           &
                 ,xlv=xlv,rv=rv                                                   &
                 ,ep1=ep1,ep2=ep2,karman=karman                                   &
                 ,dz8w2d=dz8w(its:ite,kts:kte,j)                                  &
                 ,psfcpa=psfc(its:ite,j),znt=znt(its:ite,j),ust=ust(its:ite,j)   &
                 ,hpbl=hpbl(its:ite,j)                                            &
                 ,psim=psim(its:ite,j),psih=psih(its:ite,j)                       &
                 ,xland=xland(its:ite,j),hfx=hfx(its:ite,j),qfx=qfx(its:ite,j)   &
                 ,wspd=wspd(its:ite,j),br=br(its:ite,j)                           &
                 ,dt=dt,kpbl1d=kpbl2d(its:ite,j)                                  &
                 ,exch_hx=exch_h(its:ite,kts:kte,j)                               &
                 ,exch_mx=exch_m(its:ite,kts:kte,j)                               &
                 ,wstar=wstar(its:ite,j),delta=delta(its:ite,j)                   &
                 ,u10=u10(its:ite,j),v10=v10(its:ite,j)                           &
                 ,uox=uoce(its:ite,j),vox=voce(its:ite,j)                         &
                 ,rthraten=rthraten(its:ite,kts:kte,j)                            &
                 ,ysu_topdown_pblmix=l_topdown_pblmix                             &
                 ,ctopo=ctopo(its:ite,j),ctopo2=ctopo2(its:ite,j)                 &
                 ,a_u=a_u_hv,a_v=a_v_hv,a_t=a_t_hv,a_q=a_q_hv,a_e=a_e_hv          &
                 ,b_u=b_u_hv,b_v=b_v_hv,b_t=b_t_hv,b_q=b_q_hv,b_e=b_e_hv          &
                 ,sfk=sfk_hv,vlk=vlk_hv,dlu=dl_u_hv,dlg=dlg_hv,frcurb=frcurb_hv   &
                 ,flag_bep=flag_bep                                               &
                 ,its=its,ite=ite,kte=kte,kme=kme                                 &
                 ,errmsg=errmsg,errflg=errflg                                     )
!
         do n = 1, nmix
            WRF_ACC_PARALLEL_LOOP_COLLAPSE_2
            do k = kts, kte
               do i = its, ite
                  rqmixblten(i,k,j,n) = rqmixblten_hv(i,k,n)
               end do
            end do
         end do
#if (NEED_B4B_DURING_CCPP_TESTING == 1)
         WRF_ACC_PARALLEL_LOOP_COLLAPSE_2
         do k = kts, kte
            do i = its, ite
               rthblten(i,k,j) = rthblten(i,k,j) / pi3d(i,k,j)
            end do
         end do
#endif
      endif
   enddo

 end subroutine ysu

!=================================================================================================================
 end module module_bl_ysu
!=================================================================================================================
