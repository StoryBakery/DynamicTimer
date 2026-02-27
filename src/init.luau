--[=[
	@class DynamicTimer
	
	Heartbeat 기반으로 TimeScale 조정, 예약 작업 관리, DynamicTween 생성을 지원하는 타이머입니다.
	글로벌 타이머를 공유하거나 개별 타이머를 만들어 느리거나 빠른 시간 흐름을 구현할 수 있습니다.

	`Classes.DynamicTimer:Wait` 체이닝은 호출이 시작된 시각을 기준으로 누적 시간을 계산합니다. 경과 시간이 시작 시각보다 과거로 돌아가면 체인은 즉시 취소되며, 되감기된 구간에서 다시 진행되면 남은 스케줄만 재등록됩니다.
	
	체인은 총 누적 대기 시간이 모두 지난 뒤 30초 동안 기록이 유지되고, 그 이후에는 자동으로 정리됩니다.
]=]

local RunService = game:GetService("RunService")

local Maid = require("./roblox_packages/Maid")
local Promise = require("./roblox_packages/Promise")
local Signal = require("./roblox_packages/Signal")
local ValueByPriority = require("./roblox_packages/ValueByPriority")

local DynamicTween, createDynamicTween, createDynamicTweenFromInstance = require("@self/Tween")

export type DynamicTween<V = any> = DynamicTween.DynamicTween<DynamicTimer, V>
export type DynamicTweenFromInstance = DynamicTween.DynamicTweenFromInstance

export type BaseDynamicTweenParams = DynamicTween.BaseDynamicTweenParams<DynamicTimer>
export type DynamicTweenParams<V = any> = DynamicTween.DynamicTweenParams<V>

local DynamicTimer = {}
DynamicTimer.__index = DynamicTimer
DynamicTimer.__type = "DynamicTimer"

--[=[
	시간 되돌릴 시를 위한 역사 보존시 최대 보존될 기간입니다.
	
	@default 30 
	@readonly
]=]
DynamicTimer.HISTORY_RETETION_DURATION = 30

local dynamicTimerSet: { [DynamicTimer]: true } = {}
local maxScheduleHistoryDurationChanged = Signal.new()

type PackedReturnValues = { [number]: any, n: number }

type ScheduleInfo = {
	ExecutionTime: number,
	CreationTime: number,
	Callback: (...any) -> ...any,
	IsExecuted: boolean,
	PreviousScheduleInfo: ScheduleInfo?,
	ReturnValues: PackedReturnValues?,
	ChainInfo: WaitChainInfo?,
	Duration: number,
}

type WaitChainInfo = {
	Timer: DynamicTimer,
	StartTime: number,
	TotalDuration: number,
	ExpirationTime: number,
	Schedules: { ScheduleInfo },
}

type StepConnectionInfo = {
	Connection: Signal.Connection,
	CreationTime: number,
}

local scheduleListsByTimer = {} :: {
	[DynamicTimer]: {
		Pending: { ScheduleInfo },
		Completed: { ScheduleInfo },
	},
}

local waitChainInfosByTimer = {} :: { [DynamicTimer]: { WaitChainInfo } }
type ProgressSession = {
	Timer: DynamicTimer,
	StartTime: number,
	EndTime: number,
	Duration: number,
	Callback: (progress: number) -> (),
	IsCompleted: boolean,
	ExpirationTime: number,
	LastProgressValue: number?,
}

local progressSessionsByTimer = {} :: { [DynamicTimer]: { ProgressSession } }

local function getWaitChainsForTimer(timer: DynamicTimer): { WaitChainInfo }
	local chainInfos = waitChainInfosByTimer[timer]
	if not chainInfos then
		chainInfos = {}
		waitChainInfosByTimer[timer] = chainInfos
	end
	return chainInfos
end

local function registerWaitChain(timer: DynamicTimer, chainInfo: WaitChainInfo)
	table.insert(getWaitChainsForTimer(timer), chainInfo)
end

local function removeWaitChain(timer: DynamicTimer, chainInfo: WaitChainInfo)
	local chainInfos = waitChainInfosByTimer[timer]
	if not chainInfos then
		return
	end

	for index = #chainInfos, 1, -1 do
		if chainInfos[index] == chainInfo then
			table.remove(chainInfos, index)
			break
		end
	end

	if #chainInfos == 0 then
		waitChainInfosByTimer[timer] = nil
	end
end

local function updateChainDuration(chainInfo: WaitChainInfo)
	local maxDuration = 0
	for _, schedule in ipairs(chainInfo.Schedules) do
		local durationFromStart = math.max(0, schedule.ExecutionTime - chainInfo.StartTime)
		if durationFromStart > maxDuration then
			maxDuration = durationFromStart
		end
	end

	chainInfo.TotalDuration = maxDuration
	chainInfo.ExpirationTime = chainInfo.StartTime
		+ maxDuration
		+ DynamicTimer.HISTORY_RETETION_DURATION
end

local function registerScheduleWithChain(chainInfo: WaitChainInfo, schedule: ScheduleInfo)
	schedule.ChainInfo = chainInfo
	table.insert(chainInfo.Schedules, schedule)
	updateChainDuration(chainInfo)
end

local function removeScheduleFromChain(schedule: ScheduleInfo)
	local chainInfo = schedule.ChainInfo
	if not chainInfo then
		return
	end

	for index = #chainInfo.Schedules, 1, -1 do
		if chainInfo.Schedules[index] == schedule then
			table.remove(chainInfo.Schedules, index)
			break
		end
	end

	schedule.ChainInfo = nil

	if #chainInfo.Schedules == 0 then
		removeWaitChain(chainInfo.Timer, chainInfo)
	else
		updateChainDuration(chainInfo)
	end
end

local function cancelWaitChain(
	timer: DynamicTimer,
	chainInfo: WaitChainInfo,
	pendingSchedules: { ScheduleInfo },
	completedSchedules: { ScheduleInfo }
)
	for index = #pendingSchedules, 1, -1 do
		local info = pendingSchedules[index]
		if info.ChainInfo == chainInfo then
			table.remove(pendingSchedules, index)
			removeScheduleFromChain(info)
		end
	end

	for index = #completedSchedules, 1, -1 do
		local info = completedSchedules[index]
		if info.ChainInfo == chainInfo then
			table.remove(completedSchedules, index)
			removeScheduleFromChain(info)
		end
	end

	removeWaitChain(timer, chainInfo)
end

local function pruneExpiredWaitChains(
	timer: DynamicTimer,
	schedules: { Pending: { ScheduleInfo }, Completed: { ScheduleInfo } }
)
	local chainInfos = waitChainInfosByTimer[timer]
	if not chainInfos then
		return
	end

	for index = #chainInfos, 1, -1 do
		local chainInfo = chainInfos[index]
		if timer.ElapsedTime >= chainInfo.ExpirationTime then
			cancelWaitChain(timer, chainInfo, schedules.Pending, schedules.Completed)
		end
	end
end

local function getProgressSessionsForTimer(timer: DynamicTimer): { ProgressSession }
	local sessions = progressSessionsByTimer[timer]
	if not sessions then
		sessions = {}
		progressSessionsByTimer[timer] = sessions
	end
	return sessions
end

local function computeProgressFromSession(session: ProgressSession, currentTime: number): number
	if session.Duration <= 0 then
		return if currentTime >= session.StartTime then 1 else 0
	end

	local elapsed = math.clamp(currentTime - session.StartTime, 0, session.Duration)
	return elapsed / session.Duration
end

local function updateProgressSession(session: ProgressSession, currentTime: number)
	if currentTime < session.StartTime then
		return false
	end

	local progress = computeProgressFromSession(session, currentTime)
	if session.LastProgressValue == nil or progress ~= session.LastProgressValue then
		session.LastProgressValue = progress
		session.Callback(progress)
	end

	if not session.IsCompleted and currentTime >= session.EndTime then
		session.IsCompleted = true
		session.ExpirationTime = currentTime + DynamicTimer.HISTORY_RETETION_DURATION
	end

	if session.IsCompleted and currentTime >= session.ExpirationTime then
		return true
	end

	return false
end

local function processProgressSessions(timer: DynamicTimer)
	local sessions = progressSessionsByTimer[timer]
	if not sessions then
		return
	end

	local currentTime = timer.ElapsedTime
	for index = #sessions, 1, -1 do
		local session = sessions[index]
		local shouldRemove = updateProgressSession(session, currentTime)
		if shouldRemove then
			table.remove(sessions, index)
		end
	end

	if #sessions == 0 then
		progressSessionsByTimer[timer] = nil
	end
end

local function handleProgressSessionsForRewind(timer: DynamicTimer, newElapsedTime: number)
	local sessions = progressSessionsByTimer[timer]
	if not sessions then
		return
	end

	for index = #sessions, 1, -1 do
		local session = sessions[index]
		if session.StartTime > newElapsedTime then
			table.remove(sessions, index)
		else
			session.LastProgressValue = nil
			if session.EndTime > newElapsedTime then
				session.IsCompleted = false
				session.ExpirationTime = session.EndTime + DynamicTimer.HISTORY_RETETION_DURATION
			end
		end
	end

	if #sessions == 0 then
		progressSessionsByTimer[timer] = nil
	end
end

local function executeSchedule(info: ScheduleInfo)
	local args: PackedReturnValues = { n = 0 }
	if info.PreviousScheduleInfo then
		args = info.PreviousScheduleInfo.ReturnValues or args
	end

	local results = table.pack(info.Callback(table.unpack(args, 1, args.n)))
	info.ReturnValues = results
end

export type DynamicTimer = setmetatable<{
	IsDestroyed: boolean,
	Destroying: Signal.Signal<>,
	Maid: Maid.Maid,

	TimeScaleChanged: Signal.ChangedSignal<number>,

	--[=[
		ElapsedTime 이 변경될 때 실행됩니다, 단 타임스케일에 따라 자동으로 올라가는 경우 실행되지 않습니다.
		시간 조작에 감지를 위한 시그널.
	]=]
	ElapsedTimeChanged: Signal.ChangedSignal<number>,

	_currentTimeScale: number,
	ElapsedTime: number,

	_valueByPriority: ValueByPriority.ValueByPriority?,

	_stepSignalsByEventName: { [string]: Signal.Signal },
	_stepConnInfoSetsByEventName: { [string]: { StepConnectionInfo } },

	_root: DynamicTimer?,
	_chainInfo: WaitChainInfo?,
	_lastScheduleInChain: ScheduleInfo?,
	_chainedWaitDuration: number?,
}, typeof(DynamicTimer)>

local function newSchedule(
	executionTime: number,
	creationTime: number,
	duration: number,
	callback: (...any) -> ...any,
	previousEntry: ScheduleInfo?,
	chainInfo: WaitChainInfo?
): ScheduleInfo
	return {
		ExecutionTime = executionTime,
		CreationTime = creationTime,
		Callback = callback,
		IsExecuted = false,
		PreviousScheduleInfo = previousEntry,
		ReturnValues = nil,
		ChainInfo = chainInfo,
		Duration = duration,
	}
end

local function baseNew()
	local self = setmetatable({}, DynamicTimer)

	self.IsDestroyed = false
	self.Destroying = Signal.new()
	self.Maid = Maid.new()

	self.TimeScaleChanged = Signal.new()
	self.ElapsedTimeChanged = Signal.new()

	self._currentTimeScale = 1
	self.ElapsedTime = 0
	self._stepSignalsByEventName = {}
	self._stepConnInfoSetsByEventName = {}
	self._root = nil
	self._chainInfo = nil
	self._lastScheduleInChain = nil
	self._chainedWaitDuration = nil

	dynamicTimerSet[self] = true
	scheduleListsByTimer[self] = {
		Pending = {},
		Completed = {},
	}

	self.Maid:GiveTask(function()
		dynamicTimerSet[self] = nil
		scheduleListsByTimer[self] = nil
		waitChainInfosByTimer[self] = nil
		progressSessionsByTimer[self] = nil
	end)

	return self
end

--[=[
	@constructor
	
	기본 TimeScale 1로 작동하는 타이머를 생성합니다.
	@return - 새 타이머.
]=]
function DynamicTimer.new(): DynamicTimer
	return baseNew()
end

local function normalizeTimeScale(timeScale: number, source: string): number
	if timeScale < 0 then
		warn(`DynamicTimer: negative TimeScale "{timeScale}" from {source}; clamped to 0.`)
		return 0
	end

	return timeScale
end

local function detectTimeScaleChangedFromValueByPriority(self: DynamicTimer, getValue)
	local vbp = self._valueByPriority
	local timeScaleChanged = self.TimeScaleChanged
	local vbpChangedConnection

	if getValue then
		local lastValue = normalizeTimeScale(getValue(vbp:GetValue()), "ValueByPriority")
		self._currentTimeScale = lastValue
		vbpChangedConnection = vbp.Changed:Connect(function(new)
			local currentTimeScale = normalizeTimeScale(getValue(new), "ValueByPriority")
			if currentTimeScale ~= lastValue then
				lastValue = currentTimeScale
				self._currentTimeScale = currentTimeScale
				timeScaleChanged:Fire(currentTimeScale)
			end
		end)
	else
		local lastValue = normalizeTimeScale(vbp:GetValue(), "ValueByPriority")
		self._currentTimeScale = lastValue
		vbpChangedConnection = vbp.Changed:Connect(function(new)
			local currentTimeScale = normalizeTimeScale(new, "ValueByPriority")
			if currentTimeScale ~= lastValue then
				lastValue = currentTimeScale
				self._currentTimeScale = currentTimeScale
				timeScaleChanged:Fire(currentTimeScale)
			end
		end)
	end

	self.Maid:GiveTask(vbpChangedConnection)
end

--[=[
	@constructor
	
	ValueByPriority 값을 기반으로 TimeScale을 자동 조정하는 타이머를 생성합니다.
	음수 값이 들어오면 경고를 출력하고 0으로 처리합니다.
	
	@param valueByPriority - TimeScale을 계산할 노드.
	@param getValue ((Value) -> - 노드 값에서 TimeScale을 추출하는 함수.
	@return DynamicTimer -- 생성된 타이머.
]=]
function DynamicTimer.fromValueByPriority<Value>(
	valueByPriority: ValueByPriority.ValueByPriority<Value>,
	getValue: ((new: Value) -> number)?
): DynamicTimer
	local self = baseNew()
	self._valueByPriority = valueByPriority or error("No ValueByPriority.")
	detectTimeScaleChangedFromValueByPriority(self, getValue)
	return self
end

--[=[
	모든 연결과 예약을 정리하고 타이머를 종료합니다.
]=]
function DynamicTimer:Destroy()
	if self.IsDestroyed then
		return
	end

	self.IsDestroyed = true
	self.Destroying:Fire()
	self.Maid:Destroy()

	table.freeze(self :: any)
end

--[=[
	타이머의 TimeScale이 반영된 DynamicTween을 생성합니다.
	@param params - 트윈 생성 파라미터.
	@return DynamicTween.DynamicTween<Value> -- 생성된 DynamicTween.
]=]
function DynamicTimer:CreateTween<Value>(params: DynamicTweenParams<Value>): DynamicTween<Value>
	return createDynamicTween(self, params)
end

--[=[
	Instance 속성 값을 대상으로 하는 DynamicTween을 생성합니다.
	@param ... - DynamicTween.fromInstance에 전달할 인자.
	@return DynamicTween.DynamicTweenFromInstance -- 생성된 DynamicTween.
]=]
function DynamicTimer:CreateTweenFromInstance(
	instance: Instance,
	params: BaseDynamicTweenParams,
	propertyMap: { [string]: any }
): DynamicTweenFromInstance
	return createDynamicTweenFromInstance(self, instance, params, propertyMap)
end

--[=[
	타이머의 시간 배율(TimeScale)을 설정합니다.
	음수 값이 들어오면 경고를 출력하고 0으로 처리합니다.
	@param timeScale - 적용할 배율.
]=]
function DynamicTimer:SetTimeScale(timeScale: number)
	local normalizedTimeScale = normalizeTimeScale(timeScale, "SetTimeScale")
	if self._currentTimeScale == normalizedTimeScale then
		return
	end
	self._currentTimeScale = normalizedTimeScale
	self.TimeScaleChanged:Fire(normalizedTimeScale)
end

--[=[
	현재 TimeScale 값을 반환합니다.
	@return number -- TimeScale.
]=]
function DynamicTimer:GetTimeScale(): number
	return self._currentTimeScale
end

--[=[
	누적 경과 시간을 반환합니다.
	@return number -- 경과 시간(초).
]=]
function DynamicTimer:GetElapsedTime(): number
	return self.ElapsedTime
end

--[=[
	누적 경과 시간을 수동으로 설정합니다. 시간이 과거로 이동하면 이후에 생성된 스케줄은 삭제되고,
	이미 실행됐던 스케줄이라도 재실행 가능한 시점이라면 다시 대기열에 넣습니다. 또한 되감기 구간에서
	생성된 Heartbeat 연결도 정리됩니다.
	@param newElapsedTime - 설정할 시간(초).
]=]
function DynamicTimer:SetElapsedTime(newElapsedTime: number)
	local previousTime = self.ElapsedTime
	if previousTime == newElapsedTime then
		return
	end

	self.ElapsedTime = newElapsedTime
	self.ElapsedTimeChanged:Fire(newElapsedTime)

	if newElapsedTime < previousTime then -- Rewind
		local schedules = scheduleListsByTimer[self]
		if schedules then
			local pendingSchedules = schedules.Pending
			local completedSchedules = schedules.Completed

			local chainInfos = waitChainInfosByTimer[self]
			if chainInfos then
				for index = #chainInfos, 1, -1 do
					local chainInfo = chainInfos[index]
					if chainInfo.StartTime > newElapsedTime then
						cancelWaitChain(self, chainInfo, pendingSchedules, completedSchedules)
					end
				end
			end

			for i = #pendingSchedules, 1, -1 do
				local info = pendingSchedules[i]
				if info.CreationTime > newElapsedTime then
					table.remove(pendingSchedules, i)
					removeScheduleFromChain(info)
				end
			end

			for i = #completedSchedules, 1, -1 do
				local info = completedSchedules[i]
				if info.CreationTime > newElapsedTime then
					table.remove(completedSchedules, i)
					removeScheduleFromChain(info)
				end
			end

			local schedulesToRequeue = {}
			for i = #completedSchedules, 1, -1 do
				local info = completedSchedules[i]
				if info.ExecutionTime > newElapsedTime then
					info.IsExecuted = false
					info.ReturnValues = nil
					table.insert(schedulesToRequeue, info)
					table.remove(completedSchedules, i)
				end
			end

			if #schedulesToRequeue > 0 then
				for _, info in ipairs(schedulesToRequeue) do
					table.insert(pendingSchedules, info)
				end
				table.sort(pendingSchedules, function(a, b)
					return a.ExecutionTime < b.ExecutionTime
				end)
			end

			local remainingChains = waitChainInfosByTimer[self]
			if remainingChains then
				for _, chainInfo in ipairs(remainingChains) do
					updateChainDuration(chainInfo)
				end
			end
		end

		handleProgressSessionsForRewind(self, newElapsedTime)

		for _, connections in pairs(self._stepConnInfoSetsByEventName) do
			for connInfo in pairs(connections) do
				if connInfo.CreationTime > newElapsedTime then
					connInfo.Connection:Disconnect()
					connections[connInfo] = nil
				end
			end
		end
	else -- Fast-forward
		local schedules = scheduleListsByTimer[self]
		if schedules then
			local pending = schedules.Pending
			local completed = schedules.Completed
			while #pending > 0 and pending[1].ExecutionTime <= newElapsedTime do
				local info = table.remove(pending, 1)
				info.IsExecuted = true
				table.insert(completed, info)
				executeSchedule(info)
			end
		end
	end

	processProgressSessions(self)
end

--[=[
	콜백을 통해 새로운 경과 시간을 계산해 반영합니다.
	@param callback (currentTime: number) -> - 새 시간을 반환하는 함수.
]=]
function DynamicTimer:UpdateElapsedTime(callback: (currentTime: number) -> number)
	self:SetElapsedTime(callback(self.ElapsedTime))
end

local chainContextKeys = {
	_root = true,
	_chainInfo = true,
	_lastScheduleInChain = true,
	_chainedWaitDuration = true,
}

local function createWaitChainContext(
	rootTimer: DynamicTimer,
	chainedWaitDuration: number,
	lastScheduleInChain: ScheduleInfo,
	chainInfo: WaitChainInfo
): DynamicTimer
	local chained = {
		_root = rootTimer,
		_chainedWaitDuration = chainedWaitDuration,
		_lastScheduleInChain = lastScheduleInChain,
		_chainInfo = chainInfo,
	}

	return setmetatable(chained, {
		__index = function(_, key)
			if key == "Wait" then
				return DynamicTimer.Wait
			end

			local value = rootTimer[key]
			if typeof(value) == "function" then
				return function(_, ...)
					return value(rootTimer, ...)
				end
			end

			return value
		end,
		__newindex = function(selfProxy, key, value)
			if chainContextKeys[key] then
				rawset(selfProxy, key, value)
				return
			end
			rootTimer[key] = value
		end,
	}) :: any
end

--[=[
	TimeScale을 고려해 지정한 시간만큼 대기하는 스케줄을 체이닝 방식으로 등록합니다. 체인은 처음 `:Wait`
	가 호출된 시각을 기준으로 누적 시간이 계산되며, 경과 시간을 과거로 되감으면 아직 진행되지 않은
	콜백이 다시 재생될 준비를 합니다. 시작 시각 이전으로 돌아가면 해당 체인은 모두 취소됩니다.
	
	```lua
	timer:Wait(1, function()
		print("1초 후 실행")
		return "Next", 100
	end):Wait(2, function(message, value)
		-- 이전 콜백의 반환값을 인자로 전달받음
		print("총 3초 경과:", message, value)
	end)
	```
	
	체인으로 하는 이유는, 시간을 되돌릴 때 쉽게 반복할 수 있게하기 위함입니다
	
	@param duration - 체인에 추가할 구간 (초).
	@param callback ((...any) -> - 이전 콜백의 반환값을 인수로 받아 실행될 함수.
	
	@return DynamicTimer -- 동일 타이머 인터페이스를 노출하는 체인 컨텍스트.
]=]
function DynamicTimer:Wait(duration: number, callback: (...any) -> ...any): DynamicTimer
	local rootTimer = self._root or self
	if rootTimer.IsDestroyed then
		return self
	end

	assert(duration, "Missing Duration")

	assert(callback, "Missing Callback")

	local creationTime = rootTimer.ElapsedTime
	local previousEntry = self._lastScheduleInChain
	local chainedWaitDuration = (self._chainedWaitDuration or 0) + duration

	local chainInfo = self._chainInfo
	if not chainInfo then
		chainInfo = {
			Timer = rootTimer,
			StartTime = creationTime,
			TotalDuration = 0,
			ExpirationTime = creationTime + DynamicTimer.HISTORY_RETETION_DURATION,
			Schedules = {},
		}
		registerWaitChain(rootTimer, chainInfo)
	end

	local targetTime = chainInfo.StartTime + chainedWaitDuration

	local schedules = scheduleListsByTimer[rootTimer]
	local entry =
		newSchedule(targetTime, creationTime, duration, callback, previousEntry, chainInfo)

	registerScheduleWithChain(chainInfo, entry)

	local pendingSchedules = schedules.Pending
	local inserted = false
	for i = 1, #pendingSchedules do
		if pendingSchedules[i].ExecutionTime > entry.ExecutionTime then
			table.insert(pendingSchedules, i, entry)
			inserted = true
			break
		end
	end
	if not inserted then
		table.insert(pendingSchedules, entry)
	end

	local chained = createWaitChainContext(rootTimer, chainedWaitDuration, entry, chainInfo)

	return chained
end

--[=[
	0~1 progress 값을 업데이트하며 지정된 시간 동안 콜백을 실행합니다. 완료 후 30초 동안 기록을 유지해
	되감으면 다시 재생되며, 시작 이전으로 돌아가면 기록이 제거됩니다.
	@param duration - 총 지속 시간.
	@param callback (progress: number) -> - 매 프레임 호출될 함수.
]=]
function DynamicTimer:RunWithProgress(
	duration: number,
	onProgress: (progress: number) -> ()
): DynamicTimer
	if self.IsDestroyed then
		return self
	end

	local startTime = self.ElapsedTime
	local sessionDuration = math.max(duration, 0)
	local endTime = startTime + sessionDuration
	local session: ProgressSession = {
		Timer = self,
		StartTime = startTime,
		EndTime = endTime,
		Duration = sessionDuration,
		Callback = onProgress,
		IsCompleted = false,
		ExpirationTime = endTime + DynamicTimer.HISTORY_RETETION_DURATION,
		LastProgressValue = nil,
	}

	table.insert(getProgressSessionsForTimer(self), session)
	updateProgressSession(session, self.ElapsedTime)

	return self
end

local function connectToStepEvent(
	self: DynamicTimer,
	eventName: string,
	func: (deltaTime: number) -> ()
): Signal.Connection
	-- 이벤트에 대한 시그널이 없으면 새로 생성합니다.
	if not self._stepSignalsByEventName[eventName] then
		self._stepSignalsByEventName[eventName] = Signal.Immediate.new()
	end
	local signal = self._stepSignalsByEventName[eventName]

	-- 이벤트에 대한 연결 목록이 없으면 새로 생성합니다.
	if not self._stepConnInfoSetsByEventName[eventName] then
		self._stepConnInfoSetsByEventName[eventName] = {}
	end
	local connInfoSet = self._stepConnInfoSetsByEventName[eventName]

	local conn = signal:Connect(func)
	local connInfo: StepConnectionInfo = {
		Connection = conn,
		CreationTime = self.ElapsedTime,
	}
	connInfoSet[connInfo] = true

	return setmetatable({
		Disconnect = function()
			conn:Disconnect()
			connInfoSet[connInfo] = nil
		end,
	}, {
		__index = conn,
	}) :: any
end

--[=[
	Heartbeat 이벤트에 연결해 TimeScale이 반영된 deltaTime을 제공합니다.
	@param func (deltaTime: number) -> - 호출될 함수.
	@return Signal.Connection -- 연결 객체.
]=]
function DynamicTimer:ConnectHeartbeat(func: (deltaTime: number) -> ()): Signal.Connection
	return connectToStepEvent(self, "Heartbeat", func)
end

--[=[
	RenderStepped 이벤트에 연결합니다.
	@param func (deltaTime: number) -> ()
	@return Signal.Connection -- 연결 객체.
]=]
function DynamicTimer:ConnectRenderStepped(func: (deltaTime: number) -> ()): Signal.Connection
	return connectToStepEvent(self, "RenderStepped", func)
end

--[=[
	Stepped 이벤트에 연결합니다.
	@param func (deltaTime: number) -> ()
	@return Signal.Connection -- 연결 객체.
]=]
function DynamicTimer:ConnectStepped(func: (deltaTime: number) -> ()): Signal.Connection
	return connectToStepEvent(self, "Stepped", func)
end

--[=[
	PreSimulation 이벤트에 연결합니다.
	@param func (deltaTime: number) -> ()
	@return Signal.Connection -- 연결 객체.
]=]
function DynamicTimer:ConnectPreSimulation(func: (deltaTime: number) -> ()): Signal.Connection
	return connectToStepEvent(self, "PreSimulation", func)
end

--[=[
	PostSimulation 이벤트에 연결합니다.
	@param func (deltaTime: number) -> ()
	@return Signal.Connection -- 연결 객체.
]=]
function DynamicTimer:ConnectPostSimulation(func: (deltaTime: number) -> ()): Signal.Connection
	return connectToStepEvent(self, "PostSimulation", func)
end

--[=[
	예약 히스토리를 유지할 최대 시간을 설정합니다.
	@param duration - 초 단위 지속 시간.
]=]
function DynamicTimer.SetMaxScheduleHistoryDuration(duration: number)
	local previousDuration = DynamicTimer.HISTORY_RETETION_DURATION
	if previousDuration == duration then
		return
	end

	DynamicTimer.HISTORY_RETETION_DURATION = duration

	local historyDurationDelta = duration - previousDuration

	for _, chainInfos in waitChainInfosByTimer do
		for _, chainInfo in ipairs(chainInfos) do
			updateChainDuration(chainInfo)
		end
	end

	if historyDurationDelta ~= 0 then
		for _, sessions in progressSessionsByTimer do
			for _, session in ipairs(sessions) do
				session.ExpirationTime += historyDurationDelta
			end
		end
	end

	maxScheduleHistoryDurationChanged:Fire(duration)
end

--[=[
	히스토리 지속 시간 변경을 알리는 시그널을 반환합니다.
	@return Signal.ChangedSignal<number> -- 변경 시그널.
]=]
function DynamicTimer.GetMaxScheduleHistoryDurationChangedSignal(): Signal.ChangedSignal<number>
	return maxScheduleHistoryDurationChanged
end

-- 모든 RunService 이벤트를 감지하여 각 타이머에 맞는 신호를 발생시킵니다.

local function onSteppedFromEvent(dt, eventName)
	for timer in dynamicTimerSet do
		if timer.IsDestroyed then
			continue
		end

		local signal = timer._stepSignalsByEventName[eventName]
		if signal then
			local scaledDt = dt * timer._currentTimeScale
			signal:Fire(scaledDt)
		end
	end
end

do
	local eventNames = {
		"Heartbeat",
		"Stepped",
		"PreSimulation",
		"PostSimulation",
	}

	if RunService:IsClient() then
		table.insert(eventNames, "RenderStepped")
	end

	for _, eventName in eventNames do
		RunService[eventName]:Connect(function(primaryDeltaTime, secondaryDeltaTime)
			local deltaTime = if eventName == "Stepped"
				then secondaryDeltaTime
				else primaryDeltaTime
			onSteppedFromEvent(deltaTime, eventName)
		end)
	end
end
RunService.Heartbeat:Connect(function(dt)
	for timer in dynamicTimerSet do
		if timer.IsDestroyed then
			continue
		end

		local scaledDt = dt * timer._currentTimeScale
		timer.ElapsedTime += scaledDt

		local schedules = scheduleListsByTimer[timer]
		if schedules then
			local pendingSchedules = schedules.Pending
			local completedSchedules = schedules.Completed

			while
				#pendingSchedules > 0 and pendingSchedules[1].ExecutionTime <= timer.ElapsedTime
			do
				local info = table.remove(pendingSchedules, 1)
				info.IsExecuted = true
				table.insert(completedSchedules, info)
				executeSchedule(info)
			end

			pruneExpiredWaitChains(timer, schedules)
			processProgressSessions(timer)

			local pruneTime = timer.ElapsedTime - DynamicTimer.HISTORY_RETETION_DURATION
			if pruneTime > 0 then
				local newCompleted = {}
				local hasRemoved = false
				for _, info in ipairs(completedSchedules) do
					local shouldKeep = true
					local chainInfo = info.ChainInfo
					if info.ExecutionTime < pruneTime then
						if chainInfo then
							if timer.ElapsedTime >= chainInfo.ExpirationTime then
								shouldKeep = false
							end
						else
							shouldKeep = false
						end
					end

					if shouldKeep then
						table.insert(newCompleted, info)
					else
						removeScheduleFromChain(info)
						hasRemoved = true
					end
				end
				if hasRemoved then
					schedules.Completed = newCompleted
				end
			end
		end
	end
end)

DynamicTimer.GlobalTimer = DynamicTimer.new()

local function initUITimer()
	local uiTimer = DynamicTimer.new()
	uiTimer:SetTimeScale(DynamicTimer.GlobalTimer:GetTimeScale())

	DynamicTimer.GlobalTimer.TimeScaleChanged:Connect(function(scale)
		if uiTimer.IsDestroyed then
			return
		end
		uiTimer:SetTimeScale(scale)
	end)

	return uiTimer
end

DynamicTimer.UITimer = initUITimer()

return DynamicTimer.GlobalTimer
