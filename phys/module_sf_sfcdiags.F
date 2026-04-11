!WRF:MODEL_LAYER:PHYSICS
!
MODULE module_sf_sfcdiags

CONTAINS

   SUBROUTINE SFCDIAGS(HFX,QFX,TSK,QSFC,CHS2,CQS2,T2,TH2,Q2,       &
                     PSFC,CP,R_d,ROVCP,CHS,T3D,QV3D,UA_PHYS,       &
                     ids,ide, jds,jde, kds,kde,                    &
                     ims,ime, jms,jme, kms,kme,                    &
                     its,ite, jts,jte, kts,kte,                    &
                     LH,SFCEVP,ACHFX,ACLHF,DT,DTBL                 )
!-------------------------------------------------------------------
      IMPLICIT NONE
!-------------------------------------------------------------------
      INTEGER,  INTENT(IN )   ::        ids,ide, jds,jde, kds,kde, &
                                        ims,ime, jms,jme, kms,kme, &
                                        its,ite, jts,jte, kts,kte
      REAL,     DIMENSION( ims:ime, jms:jme )                    , &
                INTENT(IN)                  ::                HFX, &
                                                              QFX, &
                                                              TSK, &
                                                             QSFC
      REAL,     DIMENSION( ims:ime, jms:jme )                    , &
                INTENT(INOUT)               ::                Q2, &
                                                             TH2, &
                                                              T2
      REAL,     DIMENSION( ims:ime, jms:jme )                    , &
                INTENT(IN)                  ::               PSFC, &
                                                             CHS2, &
                                                             CQS2
      REAL,     DIMENSION( ims:ime, jms:jme ), OPTIONAL         , &
                INTENT(IN)                  ::                 LH
      REAL,     INTENT(IN   )               ::       CP,R_d,ROVCP
      REAL,     INTENT(IN   ), OPTIONAL     ::       DT,DTBL

! UA changes
      LOGICAL, INTENT(IN) :: UA_PHYS   ! UA: flag for UA option
      REAL,    DIMENSION( ims:ime, kms:kme, jms:jme )            , &
            INTENT(IN   )    ::                           QV3D,T3D
      REAL,     DIMENSION( ims:ime, jms:jme )                    , &
                INTENT(IN)                  ::               CHS
      REAL,     DIMENSION( ims:ime, jms:jme ), OPTIONAL         , &
                INTENT(INOUT)               ::             SFCEVP, &
                                                            ACHFX, &
                                                            ACLHF

! LOCAL VARS
      INTEGER ::  I,J
      REAL    ::  RHO
      LOGICAL ::  have_sfcevp, have_achfx, have_aclhf

      have_sfcevp = PRESENT(SFCEVP) .AND. PRESENT(DTBL)
      have_achfx  = PRESENT(ACHFX)  .AND. PRESENT(DT)
      have_aclhf  = PRESENT(ACLHF)  .AND. PRESENT(LH) .AND. PRESENT(DT)

      IF ( UA_PHYS ) THEN
!$acc parallel loop collapse(2) private(rho)
         DO J=jts,jte
           DO I=its,ite
             IF ( have_sfcevp ) SFCEVP(I,J)= SFCEVP(I,J) + QFX(I,J)*DTBL
             IF ( have_achfx )  ACHFX(I,J)= ACHFX(I,J) + HFX(I,J)*DT
             IF ( have_aclhf )  ACLHF(I,J)= ACLHF(I,J) + LH(I,J)*DT
             if(CQS2(I,J).lt.1.E-5) then
                Q2(I,J)=QSFC(I,J)
             else
                Q2(I,J) = QSFC(I,J) - CHS(I,J)/CQS2(I,J)*(QSFC(I,J) - QV3D(i,1,j))
             endif
             if(CHS2(I,J).lt.1.E-5) then
                T2(I,J) = TSK(I,J)
             else
                T2(I,J) = TSK(I,J) - CHS(I,J)/CHS2(I,J)*(TSK(I,J) - T3D(i,1,j))
             endif
             TH2(I,J) = T2(I,J)*(1.E5/PSFC(I,J))**ROVCP
           ENDDO
         ENDDO
      ELSE
!$acc parallel loop collapse(2) private(rho)
         DO J=jts,jte
           DO I=its,ite
             IF ( have_sfcevp ) SFCEVP(I,J)= SFCEVP(I,J) + QFX(I,J)*DTBL
             IF ( have_achfx )  ACHFX(I,J)= ACHFX(I,J) + HFX(I,J)*DT
             IF ( have_aclhf )  ACLHF(I,J)= ACLHF(I,J) + LH(I,J)*DT
             RHO = PSFC(I,J)/(R_d * TSK(I,J))
             if(CQS2(I,J).lt.1.E-5) then
                Q2(I,J)=QSFC(I,J)
             else
#if (HWRF==1)
                Q2(I,J) = QSFC(I,J) - amax1(amin1(CHS(I,J)/CQS2(I,J),0.0),2.0)*(QSFC(I,J) - QV3D(i,1,j))
#else
                Q2(I,J) = QSFC(I,J) - QFX(I,J)/(RHO*CQS2(I,J))
#endif
             endif
             if(CHS2(I,J).lt.1.E-5) then
                T2(I,J) = TSK(I,J)
             else
#if (HWRF==1)
                T2(I,J) = TSK(I,J) - amax1(amin1(CHS(I,J)/CHS2(I,J),0.0),2.0)*(TSK(I,J) - T3D(i,1,j))
#else
                T2(I,J) = TSK(I,J) - HFX(I,J)/(RHO*CP*CHS2(I,J))
#endif
             endif
             TH2(I,J) = T2(I,J)*(1.E5/PSFC(I,J))**ROVCP
           ENDDO
         ENDDO
      ENDIF

  END SUBROUTINE SFCDIAGS

   SUBROUTINE SFCDIAGS_POST_LSM(HFX,QFX,LH,GRDFLX,TSK,QSFC,CHS2,CQS2,T2,TH2,Q2, &
                     PSFC,CP,R_d,ROVCP,CHS,T3D,QV3D,UA_PHYS,                     &
                     SFCEVP,SFCEXC,ACHFX,ACLHF,ACGRDFLX,DT,DTBL,                 &
                     ids,ide, jds,jde, kds,kde,                                  &
                     ims,ime, jms,jme, kms,kme,                                  &
                     its,ite, jts,jte, kts,kte                                   )
!-------------------------------------------------------------------
      IMPLICIT NONE
!-------------------------------------------------------------------
      INTEGER,  INTENT(IN )   ::        ids,ide, jds,jde, kds,kde, &
                                        ims,ime, jms,jme, kms,kme, &
                                        its,ite, jts,jte, kts,kte
      REAL,     DIMENSION( ims:ime, jms:jme )                    , &
                INTENT(IN)                  ::                HFX, &
                                                              QFX, &
                                                               LH, &
                                                          GRDFLX, &
                                                              TSK, &
                                                             QSFC
      REAL,     DIMENSION( ims:ime, jms:jme )                    , &
                INTENT(INOUT)               ::                Q2, &
                                                             TH2, &
                                                              T2, &
                                                          SFCEVP, &
                                                          SFCEXC
      REAL,     DIMENSION( ims:ime, jms:jme )                    , &
                INTENT(IN)                  ::               PSFC, &
                                                             CHS2, &
                                                             CQS2, &
                                                              CHS
      REAL,     DIMENSION( ims:ime, jms:jme ), OPTIONAL         , &
                INTENT(INOUT)               ::             ACHFX, &
                                                            ACLHF, &
                                                         ACGRDFLX
      REAL,     INTENT(IN   )               ::       CP,R_d,ROVCP,DT,DTBL

      LOGICAL, INTENT(IN) :: UA_PHYS
      REAL,    DIMENSION( ims:ime, kms:kme, jms:jme )            , &
            INTENT(IN   )    ::                           QV3D,T3D

      INTEGER ::  I,J
      REAL    ::  RHO
      LOGICAL ::  have_achfx, have_aclhf, have_acgrdflx

      have_achfx    = PRESENT(ACHFX)
      have_aclhf    = PRESENT(ACLHF)
      have_acgrdflx = PRESENT(ACGRDFLX)

      IF ( UA_PHYS ) THEN
!$acc parallel loop collapse(2) private(rho)
         DO J=jts,jte
           DO I=its,ite
             SFCEVP(I,J)= SFCEVP(I,J) + QFX(I,J)*DTBL
             SFCEXC(I,J)= CHS(I,J)
             IF ( have_achfx )    ACHFX(I,J)=ACHFX(I,J) + HFX(I,J)*DT
             IF ( have_aclhf )    ACLHF(I,J)=ACLHF(I,J) + LH(I,J)*DT
             IF ( have_acgrdflx ) ACGRDFLX(I,J)=ACGRDFLX(I,J) + GRDFLX(I,J)*DT
             if(CQS2(I,J).lt.1.E-5) then
                Q2(I,J)=QSFC(I,J)
             else
                Q2(I,J) = QSFC(I,J) - CHS(I,J)/CQS2(I,J)*(QSFC(I,J) - QV3D(i,1,j))
             endif
             if(CHS2(I,J).lt.1.E-5) then
                T2(I,J) = TSK(I,J)
             else
                T2(I,J) = TSK(I,J) - CHS(I,J)/CHS2(I,J)*(TSK(I,J) - T3D(i,1,j))
             endif
             TH2(I,J) = T2(I,J)*(1.E5/PSFC(I,J))**ROVCP
           ENDDO
         ENDDO
      ELSE
!$acc parallel loop collapse(2) private(rho)
         DO J=jts,jte
           DO I=its,ite
             SFCEVP(I,J)= SFCEVP(I,J) + QFX(I,J)*DTBL
             SFCEXC(I,J)= CHS(I,J)
             IF ( have_achfx )    ACHFX(I,J)=ACHFX(I,J) + HFX(I,J)*DT
             IF ( have_aclhf )    ACLHF(I,J)=ACLHF(I,J) + LH(I,J)*DT
             IF ( have_acgrdflx ) ACGRDFLX(I,J)=ACGRDFLX(I,J) + GRDFLX(I,J)*DT
             RHO = PSFC(I,J)/(R_d * TSK(I,J))
             if(CQS2(I,J).lt.1.E-5) then
                Q2(I,J)=QSFC(I,J)
             else
#if (HWRF==1)
                Q2(I,J) = QSFC(I,J) - amax1(amin1(CHS(I,J)/CQS2(I,J),0.0),2.0)*(QSFC(I,J) - QV3D(i,1,j))
#else
                Q2(I,J) = QSFC(I,J) - QFX(I,J)/(RHO*CQS2(I,J))
#endif
             endif
             if(CHS2(I,J).lt.1.E-5) then
                T2(I,J) = TSK(I,J)
             else
#if (HWRF==1)
                T2(I,J) = TSK(I,J) - amax1(amin1(CHS(I,J)/CHS2(I,J),0.0),2.0)*(TSK(I,J) - T3D(i,1,j))
#else
                T2(I,J) = TSK(I,J) - HFX(I,J)/(RHO*CP*CHS2(I,J))
#endif
             endif
             TH2(I,J) = T2(I,J)*(1.E5/PSFC(I,J))**ROVCP
           ENDDO
         ENDDO
      ENDIF

  END SUBROUTINE SFCDIAGS_POST_LSM

END MODULE module_sf_sfcdiags
