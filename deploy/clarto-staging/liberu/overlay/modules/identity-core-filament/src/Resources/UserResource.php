<?php

namespace Liberu\Foundation\IdentityFilament\Resources;

use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteAction;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Forms\Components\DateTimePicker;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Resources\Pages\PageRegistration;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Hash;
use Liberu\Foundation\IdentityFilament\Resources\UserResource\Pages\CreateUser;
use Liberu\Foundation\IdentityFilament\Resources\UserResource\Pages\EditUser;
use Liberu\Foundation\IdentityFilament\Resources\UserResource\Pages\ListUsers;

class UserResource extends Resource
{
    public static function getModel(): string
    {
        return config('auth.providers.users.model');
    }

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-user-group';

    protected static string|\UnitEnum|null $navigationGroup = 'Administration';

    protected static ?string $navigationLabel = 'Users';

    protected static ?string $recordTitleAttribute = 'name';

    /**
     * User's tenancy is owned + member teams (no single team() belongsTo),
     * so the tenant panel can't scope the resource query to one team.
     */
    public static function isScopedToTenant(): bool
    {
        return false;
    }

    public static function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                TextInput::make('name')
                    ->required()
                    ->maxLength(255),
                TextInput::make('email')
                    ->email()
                    ->required()
                    ->unique(ignoreRecord: true)
                    ->maxLength(255)
                    // The User model hides `email` from arrays, so the edit form loaded it empty and refused to save.
                    ->formatStateUsing(fn (?Model $record, ?string $state): ?string => $state ?? $record?->getAttribute('email')),
                // CLARTO: nobody types another person's password; they receive a link (App\Auth\AccessLink).
                DateTimePicker::make('email_verified_at')
                    ->label('Email verified at'),
                Select::make('roles')
                    ->relationship('roles', 'name')
                    ->multiple()
                    ->preload()
                    ->searchable()
                    // CLARTO: roles are per company (permission.teams). Filament's plain sync stored them with
                    // team_id NULL, so admins created here were not admins *of the company* (2026-11-24).
                    ->saveRelationshipsUsing(function (Model $record, ?array $state): void {
                        $previous = getPermissionsTeamId();
                        setPermissionsTeamId(\Filament\Facades\Filament::getTenant()?->getKey());
                        $record->unsetRelation('roles');
                        $record->syncRoles(array_map('intval', $state ?? []));
                        setPermissionsTeamId($previous);
                    }),
            ]);
    }

    public static function table(Table $table): Table
    {
        return $table
            ->columns([
                TextColumn::make('name')
                    ->searchable()
                    ->sortable(),
                TextColumn::make('email')
                    ->searchable()
                    ->sortable(),
                TextColumn::make('roles.name')
                    ->label('Roles')
                    ->badge(),
                IconColumn::make('email_verified_at')
                    ->label('Verified')
                    ->boolean()
                    ->getStateUsing(fn (Model $record): bool => $record->email_verified_at !== null),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->recordActions([
                EditAction::make(),
                \App\Auth\AccessLink::action(),
                DeleteAction::make(),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ])
            ->defaultSort('created_at', 'desc');
    }

    /**
     * @return array<string, PageRegistration>
     */
    public static function getPages(): array
    {
        return [
            'index' => ListUsers::route('/'),
            'create' => CreateUser::route('/create'),
            'edit' => EditUser::route('/{record}/edit'),
        ];
    }
}
