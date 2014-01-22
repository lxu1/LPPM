module RefineRemeshModule
!******************************************************************************
!	Peter A. Bosler
!	Department of Mathematics
!	University of Michigan
!	pbosler@umich.edu
!
!******************************************************************************
!
!	Defines the mesh data structure used by icosahedral triangle and cubed
!	sphere Lagrangian meshes of the sphere.
!
!	Bosler, P.A., "Particle Methods for Geophysical Flow on the Sphere," PhD Thesis; the University of Michigan, 2013.
!
!----------------
use NumberKindsModule
use SphereGeomModule
use LoggerModule
use ParticlesModule
use EdgesModule
use PanelsModule
use STRIPACKInterfaceModule
use SSRFPACKInterfaceModule
use SphereMeshModule
use TracerSetupModule
use BVESetupModule

implicit none

include 'mpif.h'

private
public RefinementSetup
public New, Delete
public LagrangianRemesh !, DirectRemesh
public InitialRefinement
public NULL_REFINE, TRACER_REFINE, RELVORT_REFINE, FLOWMAP_REFINE

!
!----------------
! Types and module constants
!----------------
!
type RefinementSetup
	real(kreal) :: maxTol			! tolerance for extrema
	real(kreal) :: varTol			! tolerance for variation
	integer(kint) :: type = NULL_REFINE	! identifier for physical data field
	integer(kint) :: tracerID
	integer(kint) :: limit
end type

integer(kint), parameter :: NULL_REFINE = 70, &
							TRACER_REFINE = 71, &
							RELVORT_REFINE = 72, &
							FLOWMAP_REFINE = 73
!
!----------------
! Interfaces
!----------------
!
interface New
	module procedure NewPrivate
	module procedure NewPrivateNull
end interface

interface Delete
	module procedure DeletePrivate
end interface

interface 
	subroutine SetTracerOnMesh(genMesh, genTracer)
		use SphereMeshModule
		use TracerSetupModule
		implicit none
		type(SphereMesh), intent(inout) :: genMesh
		type(TracerSetup), intent(in) :: genTracer
	end subroutine
end interface
						
interface
	subroutine SetVorticityOnMesh(genMesh,genVort)
		use SphereMeshModule
		use BVESetupModule
		implicit none
		type(SphereMesh), intent(inout) :: genMesh
		type(BVESetup), intent(in) :: genVort
	end subroutine
end interface
!
!----------------
! Logging
!----------------
!
logical(klog), save :: logInit = .FALSE.
type(Logger) :: log
character(len=28), save :: logKey = 'RefineRemesh'
integer(kint), parameter :: logLevel = DEBUG_LOGGING_LEVEL
character(len=128) :: logString
character(len=24) :: formatString
contains
!
!----------------
! Standard methods : Constructor / Destructor
!----------------
!
subroutine NewPrivate(self, limit, maxTol, varTol, type, tracerID)
	type(RefinementSetup), intent(out) :: self
	real(kreal), intent(in) :: maxTol, varTol, limit
	integer(kint), intent(in) :: type
	integer(kint), intent(in), optional :: tracerID
	
	if ( .NOT. logInit ) call InitLogger(log, procRank)
	
	if ( type < NULL_REFINE .OR. type > FLOWMAP_REFINE ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,logkey,' invalid refinement type.')
		return
	elseif ( type == TRACER_REFINE) then
		if ( .NOT. present(tracerID) ) then
			call LogMessage(log,ERROR_LOGGING_LEVEL,logkey,' must specify which tracer to refine.')
			return
		else 
			self%tracerID = tracerID	
		endif	
	endif
	self%limit = limit
	self%maxTol = maxTOl
	self%varTol = varTol
	self%type = type
end subroutine

subroutine NewPrivateNull(self)
	type(RefinementSetup), intent(out) :: self
	if (.NOT. logInit ) call InitLogger(log,procRank)
	self%limit = 0
	self%maxTol = 0.0_kreal
	self%varTol = 0.0_kreal
	self%type = NULL_REFINE
end subroutine

subroutine DeletePrivate(self)
	type(RefinementSetup), intent(inout) :: self
	self%type = NULL_REFINE
end subroutine
!
!----------------
! Public functions
!----------------
!
subroutine InitialRefinement(aMesh, refineTracer, updateTracerOnMesh, tracerDef, &
									refineRelVort, updateVorticityOnMesh, vortDef)
	type(SphereMesh), intent(inout) :: aMesh
	type(RefinementSetup), intent(in) :: refineTracer
	procedure(SetTracerOnMesh) :: updateTracerOnMesh
	type(TracerSetup), intent(in) :: tracerDef
	type(RefinementSetup), intent(in) :: refineRelVort
	procedure(SetVorticityOnMesh) :: updateVorticityOnMesh
	type(BVESetup), intent(in) :: vortDef
	! local variables
	integer(kint) :: refineCount, spaceLeft, j, counter1, counter2
	integer(kint) :: startIndex, nOldPanels, amrLoopCounter, limit
	logical(klog) :: keepGoing
	type(Panels), pointer :: aPanels
	logical(klog), allocatable :: refineFlag(:)
	
	! check for invalid states
	if ( refineTracer%type == TRACER_REFINE .AND. ( GetNTracer(aMesh%panels) < refineTracer%tracerID ) ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,'InitialRefinement ERROR : ','invalid tracer number.')
		return
	endif
	if ( refineTracer%type /= NULL_REFINE .AND. refineTracer%type /= TRACER_REFINE ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,'InitialRefinement ERROR : ','invalid tracer refinement type.')
		return
	endif
	if ( refineRelVort%type /= NULL_REFINE .AND. refineRelVort%type /= RELVORT_REFINE ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,'InitialRefinement ERROR : ','invalid relVort refinement type.')
		return
	endif
	if ( refineRelVort%type == NULL_REFINE .AND. refineTracer%type == NULL_REFINE ) then
		call LogMessage(log,WARNING_LOGGING_LEVEL,'InitialRefinement WARNING : ','NULL refinement data.')
		return
	endif

	aPanels => aMesh%panels
	allocate(refineFlag(aPanels%N_Max))
	refineFlag = .FALSE.
	keepGoing = .FALSE.
	!
	! 	Apply refinement criteria
	!
	limit = 0
	startIndex = 1
	if ( refineTracer%type /= NULL_REFINE ) then
		limit = max(limit,refineTracer%limit)
		call FlagPanelsForTracerMaxRefinement(refineFlag,aMesh,refineTracer,startIndex)
		counter1 = count(refineFlag)
		call FlagPanelsForTracerVariationRefinement(refineFlag,aMesh,refineTracer,startIndex)
		counter2 = count(refineFlag) - counter1
		write(formatString,'(A)') '(A,I8,A)'
		write(logString,formatString) 'tracerMax criterion triggered ', counter1, ' times.'
		call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
		write(logString,formatString) 'tracerVar criterion triggered ', counter2, ' times.'
		call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
	endif	
	if ( refineRelVort%type /= NULL_REFINE) then
		limit = max(limit,refineRelVort%limit)
		counter1 = count(refineFlag)
		call FlagPanelsForCirculationRefinement(refineFlag,aMesh,refineRelVort,startIndex)
		counter1 = count(refineFlag) - counter1
		call FlagPanelsForRelVortVariationRefinement(refineFlag,aMesh,refineRelVort,startIndex)
		counter2 = count(refineFlag) - counter2
		write(formatString,'(A)') '(A,I8,A)'
		write(logString,formatString) 'circMax criterion triggered ', counter1, ' times.'
		call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
		write(logString,formatString) 'relVortVar criterion triggered ', counter2, ' times.'
		call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
	endif
	
	refineCount = count(refineFlag)
	spaceLeft = aPanels%N_Max - aPanels%N
	
	!
	!	exit if refinement is not needed
	!
	if ( refineCount == 0 ) then
		call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ','no refinement necessary.')
		deallocate(refineFlag)
		return
	endif
		
	!
	!	check for memory, exit if insufficient
	!
	if ( spaceLeft/4 < refineCount ) then
		call LogMessage(log,WARNING_LOGGING_LEVEL,'InitRefine : ',' insufficient memory for AMR.')
		deallocate(refineFlag)
		return		
	endif
	
	keepGoing = .TRUE.
	amrLoopCounter = 0
	
	do while (keepGoing)
		amrLoopCounter = amrLoopCounter + 1
		write(logString,formatString) 'AMR loop ',amrLoopCounter,' : refining ',refineCount,' panels.'
		call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
		!
		!	Divide flagged panels
		!
		nOldPanels = aPanels%N
		do j=startIndex, aPanels%N
			if ( refineFlag(j) ) then
				call DividePanel(aMesh,j)
				refineFlag(j) = .FALSE.
			endif
		enddo
		!
		!	Ensure adjacent panels differ by no more than one mesh level
		!
		call FlagPanelsAtRefinementBoundaries(refineFlag,aMesh)
		do j=1,aPanels%N
			if ( refineFlag(j) ) then
				call DividePanel(aMesh,j)
				refineFlag(j) = .FALSE.
			endif
		enddo
		!
		!	Set data on refined mesh
		!
		if ( aMesh%nTracer > 0 ) call UpdateTracerOnMesh(aMesh,tracerDef)
		if ( aMesh%problemKind == BVE_SOLVER ) call UpdateVorticityOnMesh(aMesh,vortDef)
		!
		!	Prevent too much refinement
		!
		if ( amrLoopCounter + 1 >= limit ) then
			keepGoing = .FALSE.
			call LogMessage(log,WARNING_LOGGING_LEVEL,'InitRefine WARNING : ',' refinement limit reached.')
		endif
		!
		!	Apply refinement criteria
		!
		startIndex = nOldPanels+1
		nOldPanels = aPanels%N
		if ( refineTracer%type /= NULL_REFINE ) then
			call FlagPanelsForTracerMaxRefinement(refineFlag,aMesh,refineTracer,startIndex)
			counter1 = count(refineFlag)
			call FlagPanelsForTracerVariationRefinement(refineFlag,aMesh,refineTracer,startIndex)
			counter2 = count(refineFlag) - counter1
			write(formatString,'(A)') '(A,I8,A)'
			write(logString,formatString) 'tracerMax criterion triggered ', counter1, ' times.'
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
			write(logString,formatString) 'tracerVar criterion triggered ', counter2, ' times.'
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
		endif	
		if ( refineRelVort%type /= NULL_REFINE) then
			counter1 = count(refineFlag)
			call FlagPanelsForCirculationRefinement(refineFlag,aMesh,refineRelVort,startIndex)
			counter1 = count(refineFlag) - counter1
			call FlagPanelsForRelVortVariationRefinement(refineFlag,aMesh,refineRelVort,startIndex)
			counter2 = count(refineFlag) - counter2
			write(formatString,'(A)') '(A,I8,A)'
			write(logString,formatString) 'circMax criterion triggered ', counter1, ' times.'
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
			write(logString,formatString) 'relVortVar criterion triggered ', counter2, ' times.'
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
		endif
		!
		!	exit if refinement is not needed
		!
		if ( refineCount == 0 ) then
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ','refinement converged.')
			keepGoing = .FALSE.
		endif
		
		!
		!	check for memory, exit if insufficient
		!
		if ( spaceLeft/4 < refineCount ) then
			call LogMessage(log,WARNING_LOGGING_LEVEL,'InitRefine : ',' insufficient memory for AMR.')
			keepGoing = .FALSE.
		endif
	enddo	
	 deallocate(refineFlag)
end subroutine

subroutine LagrangianRemesh(aMesh, setVorticity, vortDef, vortRefine, &
								   setTracer, tracerDef, tracerRefine, 
								   flowMapRefine, interpSmoothTol)
! Performs a Lagrangian remeshing of a SphereMesh object.
!	The Lagrangian paramater is interpolated from the old mesh to a new mesh.
!	Materially invariant data (tracers or vorticity) are assigned to the new mesh via the interfaces "setVorticity"
!	and "setTracer," whose inputs are the interpolated Lagrangian parameters.
!	SSRFPACK provides the interpolation scheme (cubic Hermite polynomials on the Delaunay triangulation of SphereMesh particles).
!
!	If AMR is in use, this subroutine adaptively refines the new mesh using the input criteria as well.
!
!	NewMesh data are copied into the old mesh object, overwriting the previous data.
!								   
	! calling parameters
	type(SphereMesh), intent(inout) :: aMesh
	procedure(SetVorticityOnMesh) :: setVorticity
	type(BVESetup), intent(in) :: vortDef
	type(RefinementSetup), intent(in) :: vortRefine
	procedure(SetTracerOnMesh) :: setTracer
	type(TracerSetup), intent(in) :: tracerDef
	type(RefinementSetup), intent(in) :: tracerRefine
	type(RefinementSetup), intent(in) :: flowMapRefine
	real(kreal), intent(in), optional :: interpSmoothTol
	! local variables
	type(STRIPACKData) :: delTri
	type(SSRFPACKData) :: lagSource
	logical(klog) :: vectorInterp
	type(SphereMesh) :: newMesh
	type(Particles), pointer :: newParticles
	type(Edges), pointer :: newEdges
	type(Panels), pointer :: newPanels
	integer(kint) :: j, amrLoopCounter, counter1, counter2
	logical(klog), allocatable :: refineFlag(:)
	logical(klog) :: keepGoing, refineTracer, refineVort, refineFlowMap
	integer(kint) :: startIndex, nOldPanels, refineCount, spaceLeft, limit


	nullify(newParticles)
	nullify(newEdges)
	nullify(newPanels)
	vectorInterp = .TRUE.
	refineFlowMap = .FALSE.
	refineTracer = .FALSE.
	refineVort = .FALSE.
	
	call LogMessage(log,DEBUG_LOGGING_LEVEL,logkey,' entering Lagrangian remesh.')
	
	!
	!	determine what types of AMR to use
	!
	if ( tracerRefine%type == TRACER_REFINE .AND. &
		GetNTracer(aMesh%panels) <= tracerRefine%tracerID ) refineTracer = .TRUE.
	if ( vortRefine%type == RELVORT_REFINE ) refineVort = .TRUE.
	if ( flowMapRefine%type == FLOWMAP_REFINE) refineFlowMap = .TRUE.	
	
	!
	!	set existing mesh as data source for interpolation
	!
	call New(delTri,aMesh)
	call DelaunayTriangulation(delTri)
	call New(lagSource,delTri,vectorInterp)
	if ( present(interpSmoothTol) ) call SetSigmaTol(lagSource,interpSmoothTol)
	call SetSource(LagrangianParameter(lagSource,delTri))
	
	call LogMessage(log,DEBUG_LOGGING_LEVEL,logkey,' remesh source data ready.')
	
	!
	!	Build a new mesh
	!
	call New(newMesh,aMesh%panelKind,aMesh%initNest,aMesh%AMR,aMesh%nTracer,aMesh%problemKind)
	newParticles => newMesh%particles
	newEdges => newMesh%edges
	newPanels => newMesh%panels
	
	!
	!	interpolate lagrangian parameter from old mesh to new mesh
	!
	do j=1,newParticles%N
		newParticles%x0(:,j) = InterpolateVector(newParticles%x(:,j),lagSource,delTri)
		! renormalize to spherical surface
		newParticles%x0(:,j) = newParticles%x0(:,j) / &
			sqrt(sum(newParticles%x0(:,j)*newParticles%x0(:,j)))*EARTH_RADIUS
	enddo
	do j=1,newPanels%N
		newPanels%x0(:,j) = InterpolateVector(newPanels%x(:,j),lagSource,delTri)
		! renormalize
		newPanels%x0(:,j) = newPanels%x0(:,j) / &
			sqrt(sum(newPanels%x0(:,j)*newPanels%x0(:,j)))*EARTH_RADIUS
	enddo
	!
	!	set tracer values on new mesh
	!
	if ( aMesh%nTracer > 0 ) call SetTracer(newMesh,tracerDef)
	!
	!	set vorticity values on new mesh
	!
	if ( aMesh%problemKind == BVE_SOLVER ) call SetVorticity(newMesh,vortDef)
	
	call LogMessage(log,DEBUG_LOGGING_LEVEL,logkey,' new uniform mesh ready.')
	
	!
	!	AMR
	!
	if ( aMesh%AMR > 0 ) then
		allocate(refineFlag(newPanels%N_Max))
		refineFlag = .FALSE.
		startIndex = 1
		keepGoing = .FALSE.
		limit = 0
		
		!
		!	Apply refinement criteria
		!
		if ( refineTracer ) then
			limit = max(limit,tracerRefine%limit)
			call FlagPanelsForTracerMaxRefinement(refineFlag,newMesh,tracerRefine,startIndex)
			counter1 = count(refineFlag)
			call FlagPanelsForTracerVariationRefinement(refineFlag,newMesh,refineTracer,startIndex)
			counter2 = count(refineFlag) - counter1
			write(formatString,'(A)') '(A,I8,A)'
			write(logString,formatString) 'tracerMax criterion triggered ', counter1, ' times.'
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
			write(logString,formatString) 'tracerVar criterion triggered ', counter2, ' times.'
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
		endif
		if ( refineVort) then
			limit = max(limit,vortRefine%limit)
			counter1 = count(refineFlag)
			call FlagPanelsForCirculationRefinement(refineFlag,newMesh,vortRefine,startIndex)
			counter1 = count(refineFlag) - counter1
			call FlagPanelsForRelVortVariationRefinement(refineFlag,newMesh,vortRefine,startIndex)
			counter2 = count(refineFlag) - counter1
			write(formatString,'(A)') '(A,I8,A)'
			write(logString,formatString) 'circMax criterion triggered ', counter1, ' times.'
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
			write(logString,formatString) 'relVortVar criterion triggered ', counter2, ' times.'
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
		endif
		if ( refineFlowMap ) then
			limit = max(limit,flowMapRefine%limit)
			counter1 = count(refineFlag)
			call FlagPanelsForFlowMapRefinement(refineFlag,newMesh,flowMapRefine,startIndex)
			counter1 = count(refineFlag) - counter1
			write(formatString,'(A)') '(A,I8,A)'
			write(logString,formatString) 'flowMap variation criterion triggered ', counter1, ' times.'
		endif
		
		refineCount = count(refineFlag)
		spaceLeft = newPanels%N_Max - newPanels%N
		
		!
		!	exit if refinement is not needed, or insufficient memory
		!
		if ( refineCount == 0 ) then
			call LogMessage(log,TRACE_LOGGING_LEVEL,'LagRemesh : ',' no refinement necessary.')
			keepGoing = .FALSE.
		elseif ( spaceLeft/4 < refineCount ) then
			call LogMessage(log,WARNING_LOGGING_LEVEL,'LagRemesh : ','insufficient memory for AMR.')
			keepGoing = .FALSE.
		else 
			keepGoing = .TRUE.
		endif
		
		amrLoopCounter = 0
		
		do while (keepGoing) 
			amrLoopCounter = amrLoopCounter + 1

			write(logString,formatString) 'AMR loop ',amrLoopCounter,' : refining ',refineCount,' panels.'
			call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
			!
			!	divide flagged panels
			!
			nOldPanels = newPanels%N
			nOldParticles = newParticles%N
			do j=startIndex,newPanels%N
				if ( refineFlag(j) ) then
					call DividePanel(newMesh,j)
					refineFlag(j) = .FALSE.
				endif
			enddo
			!
			!	ensure adjacent panels differ by no more than one level
			!
			call FlagPanelsAtRefinementBoundaries(refineFlag,newMesh)
			do j=1,newPanels%N
				if ( refineFlag(j) ) then
					call DividePanel(newMesh,j)
					refineFlag(j) = .FALSE.
				endif
			enddo
			
			!
			!	set problem data on mesh
			!
			do j=nOldParticles+1,newParticles%N
				newParticles%x0(:,j) = InterpolateVector(newParticles%x(:,j),lagSource,delTri)
				newParticles%x0(:,j) = newParticles%x0(:,j) / &
					sqrt(sum(newParticles%x0(:,j)*newParticles%x0(:,j)))*EARTH_RADIUS
			enddo
			do j=nOldPanels+1,newPanels%N
				newPanels%x0(:,j) = InterpolateVector(newPanels%x(:,j),lagSource,delTri)
				newPanels%x0(:,j) = newPanels%x0(:,j) / & 
					sqrt(sum(newPanels%x0(:,j)*newPanels%x0(:,j)))*EARTH_RADIUS
			enddo
			if ( aMesh%nTracer > 0 ) call SetTracer(newMesh,tracerDef)
			if ( aMesh%problemKind == BVE_SOLVER) call SetVorticity(newMesh,vortDef)
			
			!
			!	prevent too much refinement
			!
			if ( amrLoopCounter + 1 >= limit ) then
				keepGoing = .FALSE.
				call LogMessage(log,WARNING_LOGGING_LEVEL,'LagRemesh WARNING :',' refinement limit reached.')
			endif
			
			!
			!	apply refinement criteria
			!
			startIndex = nOldPanels + 1 
			nOldPanels = newPanels%N
			if ( refineTracer ) then
				limit = max(limit,tracerRefine%limit)
				call FlagPanelsForTracerMaxRefinement(refineFlag,newMesh,tracerRefine,startIndex)
				counter1 = count(refineFlag)
				call FlagPanelsForTracerVariationRefinement(refineFlag,newMesh,refineTracer,startIndex)
				counter2 = count(refineFlag) - counter1
				write(formatString,'(A)') '(A,I8,A)'
				write(logString,formatString) 'tracerMax criterion triggered ', counter1, ' times.'
				call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
				write(logString,formatString) 'tracerVar criterion triggered ', counter2, ' times.'
				call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
			endif
			if ( refineVort) then
				limit = max(limit,vortRefine%limit)
				counter1 = count(refineFlag)
				call FlagPanelsForCirculationRefinement(refineFlag,newMesh,vortRefine,startIndex)
				counter1 = count(refineFlag) - counter1
				call FlagPanelsForRelVortVariationRefinement(refineFlag,newMesh,vortRefine,startIndex)
				counter2 = count(refineFlag) - counter1
				write(formatString,'(A)') '(A,I8,A)'
				write(logString,formatString) 'circMax criterion triggered ', counter1, ' times.'
				call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
				write(logString,formatString) 'relVortVar criterion triggered ', counter2, ' times.'
				call LogMessage(log,TRACE_LOGGING_LEVEL,'InitRefine : ',logString)
			endif
			if ( refineFlowMap ) then
				limit = max(limit,flowMapRefine%limit)
				counter1 = count(refineFlag)
				call FlagPanelsForFlowMapRefinement(refineFlag,newMesh,flowMapRefine,startIndex)
				counter1 = count(refineFlag) - counter1
				write(formatString,'(A)') '(A,I8,A)'
				write(logString,formatString) 'flowMap variation criterion triggered ', counter1, ' times.'
			endif
			
			refineCount = count(refineFlag)
			spaceLeft = newPanels%N_Max - newPanels%N
			
			!
			!	exit if refinement is not needed, or insufficient memory
			!
			if ( refineCount == 0 ) then
				call LogMessage(log,TRACE_LOGGING_LEVEL,'LagRemesh : ','refinement comverged.')
				keepGoing = .FALSE.
			elseif ( spaceLeft/4 < refineCount ) then
				call LogMessage(log,WARNING_LOGGING_LEVEL,'LagRemesh : ','insufficient memory to continue AMR.')
				keepGoing = .FALSE.
			else 
				keepGoing = .TRUE.
			endif			
		enddo ! while keepgoing
		deallocate(refineFlag)
	endif ! AMR			   
end subroutine


!
!----------------
! Module methods : module- or type-specific private functions
!----------------
!
subroutine FlagPanelsForTracerMaxRefinement(refineFlag,aMesh,refineTracer,startIndex)
	logical(klog), intent(inout) :: refineFlag(:)
	type(SphereMesh), intent(in) :: aMesh
	type(RefinementSetup), intent(in) :: refineTracer
	integer(kint), intent(in) :: startIndex
	! local variables
	type(Panels), pointer :: aPanels
	integer(kint) :: j
	
	if ( refineTracer%type /= TRACER_REFINE ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,'FlagPanelsTracer ERROR :',' invalid refinement type.')
		return
	endif
	aPanels => aMesh%panels	
	do j=startIndex,aPanels%N
		if ( .NOT. aPanels%hasChildren(j) ) then
			if ( abs(aPanels%tracer(j,refineTracer%tracerID))*aPanels%area(j) > refineTracer%maxTol ) refineFlag(j) = .TRUE.
		endif
	enddo
end subroutine

subroutine FlagPanelsForCirculationRefinement(refineFlag,aMesh,refineRelVort,startIndex)
	logical(klog), intent(inout) :: refineFlag(:)
	type(SphereMesh), intent(in) :: aMesh
	type(RefinementSetup), intent(in) :: refineRelVort
	integer(kint), intent(in) :: startIndex
	! local variables
	type(Panels), pointer :: aPanels
	integer(kint) :: j

	if ( refineRelVort%type /= RELVORT_REFINE ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,'FlagPanelsCirc ERROR :',' invalid refinement type.')
		return
	endif	
	aPanels => aMesh%panels
	do j=startIndex,aPanels%N
		if ( .NOT. aPanels%hasChildren(j) ) then
			if ( abs(aPanels%relVort(j))*aPanels%area(j) > refineRelVort%maxTol ) refineFlag(j) = .TRUE.
		endif
	enddo
end subroutine


subroutine FlagPanelsForTracerVariationRefinement(refineFlag,aMesh,refineTracer,startIndex)
	logical(klog), intent(inout) :: refineFlag(:)
	type(SphereMesh), intent(in) :: aMesh
	type(RefinementSetup), intent(in) :: refineTracer
	integer(kint), intent(in) :: startIndex
	! local variables
	type(Panels), pointer :: aPanels
	type(Particles), pointer :: aParticles
	integer(kint) :: edgeList(8), vertList(8), nVerts
	integer(kint) :: j, k
	real(kreal) :: maxTracer, minTracer, tracerVar

	if ( refineTracer%type /= TRACER_REFINE ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,'FlagPanelsTracer ERROR :',' invalid refinement type.')
		return
	endif	
	aParticles => aMesh%particles
	aPanels => aMesh%panels
	
	do j=startIndex,aPanels%N
		if ( .NOT. aPanels%hasChildren(j) ) then
			maxTracer = aPanels%tracer(j,refineTracer%tracerID)
			minTracer = maxTracer
			call CCWEdgesAndParticlesAroundPanel(edgeList,vertList,nVerts,aMesh,j)
			do k=1,nVerts
				if ( aParticles%tracer(vertList(k),refineTracer%tracerID) > maxTracer) &
					maxTracer = aParticles%tracer(vertList(k),refineTracer%tracerID)
				if ( aParticles%tracer(vertList(k),refineTracer%tracerID) < minTracer) &
					minTracer = aParticles%tracer(vertList(k),refineTracer%tracerID)	
			enddo
			tracerVar = maxTracer - minTracer
			if ( tracerVar > refineTracer%varTol ) refineFlag(j) = .TRUE.
		endif
	enddo
end subroutine

subroutine FlagPanelsForRelVortVariationRefinement(refineFlag,aMesh,refineRelVort,startIndex)
	logical(klog), intent(inout) :: refineFlag(:)
	type(SphereMesh), intent(in) :: aMesh
	type(RefinementSetup), intent(in) :: refineRelVort
	integer(kint), intent(in) :: startIndex
	! local variables
	type(Panels), pointer :: aPanels
	type(Particles), pointer :: aParticles
	integer(kint) :: edgeList(8), vertList(8), nVerts
	integer(kint) :: j, k
	real(kreal) :: maxRelvort, minRelvort, relVortVar

	if ( refineRelVOrt%type /= RELVORT_REFINE ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,'FlagPanelsRelVortVar ERROR :',' invalid refinement type.')
		return
	endif	
	aParticles => aMesh%particles
	aPanels => aMesh%panels
	
	do j=startIndex,aPanels%N
		if ( .NOT. aPanels%hasChildren(j) ) then
			maxrelVort = aPanels%relVort(j)
			minRelVort = maxRelVort
			call CCWEdgesAndParticlesAroundPanel(edgeList,vertList,nVerts,aMesh,j)
			do k=1,nVerts
				if ( aParticles%relVort(vertList(k)) > maxrelVort) &
					maxrelVort = aParticles%relVort(vertList(k))
				if ( aParticles%relVort(vertList(k)) < minrelVort) &
					minRelVort = aParticles%relVort(vertList(k))			
			enddo
			relVortVar = maxRelVort - minRelVort
			if ( relVortVar > refineRelVort%varTol ) refineFlag(j) = .TRUE.
		endif
	enddo
end subroutine

subroutine FlagPanelsForRelVortVariationRefinement(refineFlag,aMesh,refineFlowMap,startIndex)
	logical(klog), intent(inout) :: refineFlag(:)
	type(SphereMesh), intent(in) :: aMesh
	type(RefinementSetup), intent(in) :: refineFlowMap
	integer(kint), intent(in) :: startIndex
	! local variables
	type(Panels), pointer :: aPanels
	type(Particles), pointer :: aParticles
	integer(kint) :: edgeList(8), vertList(8), nVerts
	integer(kint) :: j, k
	real(kreal) :: maxX0(3), minX0(3), lagVar

	if ( refineRelVOrt%type /= FLOWMAP_REFINE ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,'FlagPanelsFlowMap ERROR :',' invalid refinement type.')
		return
	endif	
	aParticles => aMesh%particles
	aPanels => aMesh%panels
	
	do j=startIndex,aPanels%N
		if ( .NOT. aPanels%hasChildren(j) ) then
			maxX0 = aPanels%x0(:,j)
			minX0 = maxX0
			call CCWEdgesAndParticlesAroundPanel(edgeList,vertList,nVerts,aMesh,j)
			do k=1,nVerts
				if ( aParticles%x0(1,vertList(k)) > maxx0(1)) &
					maxx0(1) = aParticles%x0(1,vertList(k))
				if ( aParticles%x0(1,vertList(k)) < minx0(1)) &
					minx0(1) = aParticles%x0(1,vertList(k))		
				if ( aParticles%x0(2,vertList(k)) > maxx0(2)) &
					maxx0(2) = aParticles%x0(1,vertList(k))
				if ( aParticles%x0(2,vertList(k)) < minx0(2)) &
					minx0(2) = aParticles%x0(1,vertList(k))		
				if ( aParticles%x0(3,vertList(k)) > maxx0(3)) &
					maxx0(3) = aParticles%x0(1,vertList(k))
				if ( aParticles%x0(3,vertList(k)) < minx0(3)) &
					minx0(3) = aParticles%x0(1,vertList(k))				
			enddo
			lagVar = sum(maxx0 - minx0)
			if ( lagVar > refineFlowMap%varTol ) refineFlag(j) = .TRUE.
		endif
	enddo
end subroutine


subroutine InitLogger(aLog,rank)
	type(Logger), intent(inout) :: aLog
	integer(kint), intent(in) :: rank
	write(logKey,'(A,A,I0.2,A)') trim(logKey),'_',rank,' : '
	if ( rank == 0 ) then
		call New(aLog,logLevel)
	else 
		call New(aLog,WARNING_LOGGING_LEVEL)
	endif
	logInit = .TRUE.
end subroutine

end module
