--[[
	CarCatalog -- The central database of all vehicles in the game.
	Contains specifications, pricing, cardex lore, and default styling.
]]

export type CarEntry = {
	Id: string,
	DisplayName: string,
	Subtitle: string,
	Description: string,
	Price: number,
	Tier: "Starter" | "Sport" | "Super" | "Hyper" | "Classic",
	TopSpeed: number, -- studs/sec (~120 = 150 km/h)
	Acceleration: number,
	Grip: number,
	DriveType: "AWD" | "RWD" | "FWD",
	TemplateName: string,
	DefaultColor: Color3,
	AccentColor: Color3,
}

local CarCatalog = {}

local CARS: { CarEntry } = {
	{
		Id = "Porsche",
		DisplayName = "Porsche 911 Carrera",
		Subtitle = "Iconic Precision Engineering",
		Description = "A timeless German sports icon with rear-engine balance, exceptional cornering agility, and raw track pedigree.",
		Price = 0,
		Tier = "Starter",
		TopSpeed = 120,
		Acceleration = 70,
		Grip = 10,
		DriveType = "AWD",
		TemplateName = "Porsche",
		DefaultColor = Color3.fromRGB(0, 122, 204), -- Miami Blue
		AccentColor = Color3.fromRGB(70, 170, 255),
	},
	{
		Id = "ApexGT",
		DisplayName = "Apex GT3",
		Subtitle = "High-Revving Track Weapon",
		Description = "Stripped of weight and engineered for downforce, the Apex GT3 cuts through tight chicanes with pure aerodynamic poise.",
		Price = 35000,
		Tier = "Sport",
		TopSpeed = 135,
		Acceleration = 82,
		Grip = 11.5,
		DriveType = "RWD",
		TemplateName = "ApexGT",
		DefaultColor = Color3.fromRGB(245, 185, 20), -- Racing Yellow
		AccentColor = Color3.fromRGB(255, 215, 0),
	},
	{
		Id = "SpectreV10",
		DisplayName = "Spectre V10",
		Subtitle = "Naturally Aspirated Screamer",
		Description = "A mid-engine Italian supercar with an intoxicating 8,500 RPM exhaust note, carbon ceramic brakes, and active aero fins.",
		Price = 85000,
		Tier = "Super",
		TopSpeed = 155,
		Acceleration = 95,
		Grip = 12.8,
		DriveType = "AWD",
		TemplateName = "SpectreV10",
		DefaultColor = Color3.fromRGB(220, 35, 35), -- Rosso Corsa
		AccentColor = Color3.fromRGB(255, 75, 75),
	},
	{
		Id = "PhantomEV",
		DisplayName = "Phantom Hyper EV",
		Subtitle = "Instant Torque Electric Hypercar",
		Description = "Quad-motor electric powertrain delivering relentless acceleration that pushes the boundaries of g-force and tire grip.",
		Price = 175000,
		Tier = "Hyper",
		TopSpeed = 180,
		Acceleration = 120,
		Grip = 14.0,
		DriveType = "AWD",
		TemplateName = "PhantomEV",
		DefaultColor = Color3.fromRGB(130, 45, 220), -- Cyber Violet
		AccentColor = Color3.fromRGB(180, 100, 255),
	},
	{
		Id = "Monaco74",
		DisplayName = "Monaco Classic 1974",
		Subtitle = "Vintage Grand Tourer",
		Description = "Chrome bumpers, leather interior, and a roaring carbureted V8. Slower than modern hypercars, but unmatched in soul and style.",
		Price = 50000,
		Tier = "Classic",
		TopSpeed = 110,
		Acceleration = 60,
		Grip = 8.5,
		DriveType = "RWD",
		TemplateName = "Monaco74",
		DefaultColor = Color3.fromRGB(215, 85, 25), -- Sunset Tangerine
		AccentColor = Color3.fromRGB(240, 130, 60),
	},
}

function CarCatalog.getAll(): { CarEntry }
	return CARS
end

function CarCatalog.get(carId: string): CarEntry?
	for _, car in CARS do
		if car.Id == carId then
			return car
		end
	end
	return nil
end

function CarCatalog.getDefault(): CarEntry
	return CARS[1]
end

return CarCatalog
